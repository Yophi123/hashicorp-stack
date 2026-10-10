data "aws_region" "current" {}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_ami" "node" {
  region      = data.aws_region.current.region
  for_each    = var.node_groups
  most_recent = true
  owners      = var.ami_owners

  filter {
    name   = "tag:Role"
    values = [lookup(var.ami_role_tags, each.key)]
  }

  filter {
    name   = "tag:BuiltBy"
    values = ["packer"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

## IAM: shared by every node group
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Cloud auto-join for Consul, Nomad and Vault raft. DescribeInstances has no
# resource-level permissions, so "*" is the only valid resource. It is not
# region-scoped either, which is what lets the two sites find each other.
data "aws_iam_policy_document" "autojoin" {
  statement {
    sid       = "CloudAutoJoin"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

## IAM: Vault
data "aws_iam_policy_document" "vault" {
  count = contains(keys(var.node_groups), "vault") ? 1 : 0

  statement {
    sid       = "AutoUnseal"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arns.vault_unseal]
  }

  lifecycle {
    precondition {
      condition     = var.kms_key_arns.vault_unseal != null
      error_message = "kms_key_arns.vault_unseal is required when the vault node group exists."
    }
  }
}

data "aws_iam_policy_document" "vault_bootstrap" {
  count = var.enable_bootstrap_automation && contains(keys(var.node_groups), "vault") ? 1 : 0

  statement {
    sid       = "InitLock"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.bootstrap_lock[0].arn]
  }

  statement {
    sid       = "StoreInitOutput"
    effect    = "Allow"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.init_secret_arns.vault]
  }

  # The init secret is encrypted with the unseal key; writing it needs a data key.
  statement {
    sid       = "EncryptInitOutput"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.kms_key_arns.vault_unseal]
  }

  lifecycle {
    precondition {
      condition     = var.init_secret_arns.vault != null
      error_message = "init_secret_arns.vault is required when bootstrap automation is on and the vault node group exists."
    }
  }
}

## IAM: Boundary
data "aws_iam_policy_document" "boundary" {
  count = contains(keys(var.node_groups), "boundary") ? 1 : 0

  statement {
    sid     = "BoundaryKms"
    effect  = "Allow"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [
      var.kms_key_arns.boundary_root,
      var.kms_key_arns.boundary_worker_auth,
      var.kms_key_arns.boundary_recovery,
    ]
  }

  statement {
    sid       = "ReadDatabaseSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.boundary_db.secret_arn]
  }

  dynamic "statement" {
    for_each = var.boundary_db_kms_key_id == null ? [] : [var.boundary_db_kms_key_id]

    content {
      sid       = "DecryptDatabaseSecret"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }

  lifecycle {
    precondition {
      condition = alltrue([
        var.kms_key_arns.boundary_root != null,
        var.kms_key_arns.boundary_worker_auth != null,
        var.kms_key_arns.boundary_recovery != null,
      ])
      error_message = "kms_key_arns needs boundary_root, boundary_worker_auth and boundary_recovery when the boundary node group exists."
    }

    precondition {
      condition     = var.boundary_db != null
      error_message = "boundary_db is required when the boundary node group exists."
    }
  }
}

data "aws_iam_policy_document" "boundary_bootstrap" {
  count = var.enable_bootstrap_automation && contains(keys(var.node_groups), "boundary") ? 1 : 0

  statement {
    sid       = "InitLock"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.bootstrap_lock[0].arn]
  }

  statement {
    sid       = "StoreInitOutput"
    effect    = "Allow"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.init_secret_arns.boundary]
  }

  # The init secret is encrypted with the Boundary root key.
  statement {
    sid       = "EncryptInitOutput"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey"]
    resources = [var.kms_key_arns.boundary_root]
  }
}

data "aws_iam_policy_document" "vault_snapshots" {
  count = contains(keys(var.node_groups), "vault") && var.vault_snapshots != null ? 1 : 0

  statement {
    sid       = "SnapshotObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.vault_snapshots.bucket_arn}/vault/*"]
  }

  # Without ListBucket, a missing snapshot reads as "access denied" instead of "not found".
  statement {
    sid       = "SnapshotList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.vault_snapshots.bucket_arn]
  }

  # Vault's AWS auth looks up the caller's role to match it against the snapshot binding.
  statement {
    sid       = "ResolveOwnRole"
    effect    = "Allow"
    actions   = ["iam:GetRole"]
    resources = [local.vault_role_pattern]
  }

  dynamic "statement" {
    for_each = length(var.vault_snapshots.copy_to) > 0 ? [1] : []

    content {
      sid       = "SnapshotCopies"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = [for c in var.vault_snapshots.copy_to : "${c.bucket_arn}/vault/*"]
    }
  }
}

data "aws_iam_policy_document" "server_snapshots" {
  count = contains(keys(var.node_groups), "nomad_consul_server") && var.server_snapshots != null ? 1 : 0

  statement {
    sid     = "SnapshotObjects"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      "${var.server_snapshots.bucket_arn}/consul/*",
      "${var.server_snapshots.bucket_arn}/nomad/*",
    ]
  }

  # Without ListBucket, a missing snapshot reads as "access denied" instead of "not found".
  statement {
    sid       = "SnapshotList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.server_snapshots.bucket_arn]
  }
}
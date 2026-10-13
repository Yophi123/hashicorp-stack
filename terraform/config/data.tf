data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_secretsmanager_secrets" "vault_init" {
  filter {
    name   = "name"
    values = ["${var.project_name}/vault/init-"]
  }
}

## Policy for Boundary's Vault credential store (used in part 2)
data "vault_policy_document" "boundary_controller" {
  # What Boundary needs to manage its own token and the leases it hands out.
  rule {
    path         = "auth/token/lookup-self"
    capabilities = ["read"]
  }
  rule {
    path         = "auth/token/renew-self"
    capabilities = ["update"]
  }
  rule {
    path         = "auth/token/revoke-self"
    capabilities = ["update"]
  }
  rule {
    path         = "sys/leases/renew"
    capabilities = ["update"]
  }
  rule {
    path         = "sys/leases/revoke"
    capabilities = ["update"]
  }
  rule {
    path         = "sys/capabilities-self"
    capabilities = ["update"]
  }

  # The one thing it may issue: SSH certificates for host access.
  rule {
    path         = "${vault_mount.ssh.path}/issue/${vault_ssh_secret_backend_role.host_access.name}"
    capabilities = ["update"]
  }
}

# Finds each init secret by name prefix, unless its ARN is passed in init_secret_arns.
data "aws_secretsmanager_secrets" "init" {
  for_each = local.init_secrets

  filter {
    name   = "name"
    values = ["${var.project_name}/${each.key}/init-"]
  }

  lifecycle {
    postcondition {
      condition     = contains(keys(var.init_secret_arns), each.key) || length(self.arns) == 1
      error_message = <<-EOT
        Expected exactly one secret named "${var.project_name}/${each.key}/init-*" in account
        ${data.aws_caller_identity.current.account_id}, region ${data.aws_region.current.region};
        found ${length(self.arns)}. Check project_name, region and the AWS profile,
        or pass its ARN in init_secret_arns.
      EOT
    }
  }
}

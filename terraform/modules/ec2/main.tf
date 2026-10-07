locals {
  groups = keys(var.node_groups)

  has_servers  = contains(local.groups, "nomad_consul_server")
  has_workers  = contains(local.groups, "nomad_worker")
  has_vault    = contains(local.groups, "vault")
  has_boundary = contains(local.groups, "boundary")

  tags = merge(var.tags, { Project = var.project_name })

  # Ports are facts about the products, not about this deployment.
  ports = {
    ssh = 22
    consul = {
      server_rpc = 8300
      serf_lan   = 8301
      serf_wan   = 8302
      http       = 8500
      grpc       = 8502
      dns        = 8600
    }
    nomad = {
      http = 4646
      rpc  = 4647
      serf = 4648
    }
    vault = {
      api     = 8200
      cluster = 8201
    }
    boundary = {
      api     = 9200
      cluster = 9201
      proxy   = 9202
      ops     = 9203
    }
    # Nomad's dynamic port range for tasks and Envoy sidecars.
    workload = {
      min = 20000
      max = 32000
    }
  }

  # What each group listens on for the rest of the VPC (peers, the ALB, the
  # Boundary worker). Every group runs a Consul agent, hence serf_lan everywhere.
  vpc_ingress = {
    nomad_consul_server = {
      tcp = [
        local.ports.consul.server_rpc,
        local.ports.consul.serf_lan,
        local.ports.consul.serf_wan,
        local.ports.consul.http,
        local.ports.consul.grpc,
        local.ports.consul.dns,
        local.ports.nomad.http,
        local.ports.nomad.rpc,
        local.ports.nomad.serf,
      ]
      udp = [
        local.ports.consul.serf_lan,
        local.ports.consul.serf_wan,
        local.ports.consul.dns,
        local.ports.nomad.serf,
      ]
    }
    nomad_worker = {
      tcp = [local.ports.consul.serf_lan, local.ports.nomad.http]
      udp = [local.ports.consul.serf_lan]
    }
    vault = {
      tcp = [local.ports.vault.api, local.ports.vault.cluster, local.ports.consul.serf_lan]
      udp = [local.ports.consul.serf_lan]
    }
    boundary = {
      tcp = [
        local.ports.boundary.api,
        local.ports.boundary.cluster,
        local.ports.boundary.ops,
        local.ports.consul.serf_lan,
      ]
      udp = [local.ports.consul.serf_lan]
    }
  }

  vpc_rules = {
    for r in flatten([
      for group, protos in local.vpc_ingress : [
        for proto, plist in protos : [
          for p in plist : { group = group, protocol = proto, port = p }
        ]
      ] if contains(local.groups, group)
    ]) : "${r.group}-${r.protocol}-${r.port}" => r
  }

  # Server-to-server traffic between the two sites: RPC and WAN gossip only.
  federation_ingress = {
    tcp = [
      local.ports.consul.server_rpc,
      local.ports.consul.serf_wan,
      local.ports.nomad.rpc,
      local.ports.nomad.serf,
    ]
    udp = [local.ports.consul.serf_wan, local.ports.nomad.serf]
  }

  peer_rules = {
    for r in flatten([
      for cidr in var.federation.peer_vpc_cidrs : [
        for proto, plist in local.federation_ingress : [
          for p in plist : { cidr = cidr, protocol = proto, port = p }
        ]
      ]
    ]) : "${r.cidr}-${r.protocol}-${r.port}" => r
    if local.has_servers
  }

  # Cloud auto-join. The tag value is the same at both sites; the region in
  # the join string is what keeps LAN joins local and WAN joins remote.
  consul_join_tag = "${var.project_name}-nomad_consul_server"
  vault_join_tag  = "${var.project_name}-vault"

  wan_join = [
    for r in var.federation.peer_aws_regions :
    "provider=aws region=${r} tag_key=${var.retry_join_tag_key} tag_value=${local.consul_join_tag}"
  ]

  bootstrap_expect = try(var.node_groups["nomad_consul_server"].desired_capacity, 1)

  bootstrap_roles = var.enable_bootstrap_automation ? ["vault", "boundary"] : []
  lock_table      = try(aws_dynamodb_table.bootstrap_lock[0].name, "")

  instance_tags = {
    for k, g in var.node_groups : k => merge(local.tags, g.extra_tags, {
      Name                     = "${var.project_name}-${k}"
      Role                     = k
      (var.retry_join_tag_key) = "${var.project_name}-${k}"
    })
  }

  # Each launch template renders only its own entry, so a change to one
  # role's inputs re-versions that role's template and nothing else.
  user_data_vars = {
    nomad_consul_server = {
      consul_datacenter    = var.consul_datacenter
      nomad_region         = var.nomad_region
      primary_datacenter   = coalesce(var.federation.consul_primary_datacenter, var.consul_datacenter)
      authoritative_region = coalesce(var.federation.nomad_authoritative_region, var.nomad_region)
      bootstrap_expect     = local.bootstrap_expect
      ports                = local.ports
      join_tag_key         = var.retry_join_tag_key
      consul_join_tag      = local.consul_join_tag
      wan_join             = local.wan_join
    }

    nomad_worker = {
      consul_datacenter = var.consul_datacenter
      nomad_region      = var.nomad_region
      ports             = local.ports
      join_tag_key      = var.retry_join_tag_key
      consul_join_tag   = local.consul_join_tag
    }

    vault = {
      project_name      = var.project_name
      consul_datacenter = var.consul_datacenter
      ports             = local.ports
      join_tag_key      = var.retry_join_tag_key
      consul_join_tag   = local.consul_join_tag
      vault_join_tag    = local.vault_join_tag
      vault_kms_key_id  = var.kms_key_arns.vault_unseal
      vault_node_count  = try(var.node_groups["vault"].desired_capacity, 1)
      bootstrap_enabled = var.enable_bootstrap_automation
      vault_init_secret = try(aws_secretsmanager_secret.vault_init[0].arn, "")
    }

    boundary = {
      project_name         = var.project_name
      consul_datacenter    = var.consul_datacenter
      ports                = local.ports
      join_tag_key         = var.retry_join_tag_key
      consul_join_tag      = local.consul_join_tag
      boundary_kms         = var.kms_key_arns
      boundary_db          = var.boundary_db
      bootstrap_enabled    = var.enable_bootstrap_automation
      boundary_init_secret = try(aws_secretsmanager_secret.boundary_init[0].arn, "")
    }
  }
}

## Security groups
resource "aws_security_group" "node" {
  for_each = var.node_groups

  name_prefix = "${var.project_name}-${each.key}-"
  description = "Instances in the ${each.key} node group"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.project_name}-${each.key}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpc" {
  for_each = local.vpc_rules

  security_group_id = aws_security_group.node[each.value.group].id
  description       = "${upper(each.value.protocol)} ${each.value.port} from the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = each.value.protocol
}

# Tasks and sidecars on one worker must be reachable from the others and from the ALB.
resource "aws_vpc_security_group_ingress_rule" "worker_workloads" {
  for_each = toset(local.has_workers ? ["tcp", "udp"] : [])

  security_group_id = aws_security_group.node["nomad_worker"].id
  description       = "Nomad dynamic ports (${each.value}) from the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = local.ports.workload.min
  to_port           = local.ports.workload.max
  ip_protocol       = each.value
}

resource "aws_vpc_security_group_ingress_rule" "federation" {
  for_each = local.peer_rules

  security_group_id = aws_security_group.node["nomad_consul_server"].id
  description       = "${upper(each.value.protocol)} ${each.value.port} from peer site ${each.value.cidr}"
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = each.value.protocol
}

# SSH is reachable only from the Boundary worker, never from a CIDR.
resource "aws_vpc_security_group_ingress_rule" "ssh_from_boundary" {
  for_each = local.has_boundary ? var.node_groups : {}

  security_group_id            = aws_security_group.node[each.key].id
  description                  = "SSH from the Boundary worker"
  referenced_security_group_id = aws_security_group.node["boundary"].id
  from_port                    = local.ports.ssh
  to_port                      = local.ports.ssh
  ip_protocol                  = "tcp"
}

# The worker proxy is not HTTP, so clients reach it directly instead of through the ALB.
resource "aws_vpc_security_group_ingress_rule" "boundary_proxy_clients" {
  for_each = toset(local.has_boundary ? var.allowed_client_cidrs : [])

  security_group_id = aws_security_group.node["boundary"].id
  description       = "Boundary worker proxy from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = local.ports.boundary.proxy
  to_port           = local.ports.boundary.proxy
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_boundary" {
  count = local.has_boundary && var.create_rds_ingress_rule ? 1 : 0

  security_group_id            = var.boundary_db_security_group_id
  description                  = "Boundary controllers to Postgres"
  referenced_security_group_id = aws_security_group.node["boundary"].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"

  lifecycle {
    precondition {
      condition     = var.boundary_db_security_group_id != null
      error_message = "Set boundary_db_security_group_id, or set create_rds_ingress_rule = false."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = var.node_groups

  security_group_id = aws_security_group.node[each.key].id
  description       = "All egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

## IAM
resource "aws_iam_role" "node" {
  for_each = var.node_groups

  name_prefix        = "${var.project_name}-${each.key}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = merge(local.tags, { Name = "${var.project_name}-${each.key}-role" })
}

resource "aws_iam_instance_profile" "node" {
  for_each = var.node_groups

  name_prefix = "${var.project_name}-${each.key}-"
  role        = aws_iam_role.node[each.key].name

  tags = merge(local.tags, { Name = "${var.project_name}-${each.key}-profile" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "autojoin" {
  for_each = var.node_groups

  name_prefix = "autojoin-"
  role        = aws_iam_role.node[each.key].id
  policy      = data.aws_iam_policy_document.autojoin.json
}

resource "aws_iam_role_policy" "vault" {
  count = local.has_vault ? 1 : 0

  name_prefix = "vault-"
  role        = aws_iam_role.node["vault"].id
  policy      = data.aws_iam_policy_document.vault[0].json
}

resource "aws_iam_role_policy" "vault_bootstrap" {
  count = var.enable_bootstrap_automation && local.has_vault ? 1 : 0

  name_prefix = "vault-bootstrap-"
  role        = aws_iam_role.node["vault"].id
  policy      = data.aws_iam_policy_document.vault_bootstrap[0].json
}

resource "aws_iam_role_policy" "boundary" {
  count = local.has_boundary ? 1 : 0

  name_prefix = "boundary-"
  role        = aws_iam_role.node["boundary"].id
  policy      = data.aws_iam_policy_document.boundary[0].json
}

resource "aws_iam_role_policy" "boundary_bootstrap" {
  count = var.enable_bootstrap_automation && local.has_boundary ? 1 : 0

  name_prefix = "boundary-bootstrap-"
  role        = aws_iam_role.node["boundary"].id
  policy      = data.aws_iam_policy_document.boundary_bootstrap[0].json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = var.enable_ssm ? var.node_groups : {}

  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

## Bootstrap automation
resource "aws_dynamodb_table" "bootstrap_lock" {
  count = var.enable_bootstrap_automation && (local.has_vault || local.has_boundary) ? 1 : 0

  name         = "${var.project_name}-bootstrap-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockId"

  attribute {
    name = "LockId"
    type = "S"
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret" "vault_init" {
  count = var.enable_bootstrap_automation && local.has_vault ? 1 : 0

  name_prefix             = "${var.project_name}/vault/init-"
  description             = "Vault recovery keys and initial root token"
  kms_key_id              = var.kms_key_arns.vault_unseal
  recovery_window_in_days = 7

  tags = local.tags
}

resource "aws_secretsmanager_secret" "boundary_init" {
  count = var.enable_bootstrap_automation && local.has_boundary ? 1 : 0

  name_prefix             = "${var.project_name}/boundary/init-"
  description             = "Boundary initial admin credentials and auth method ID"
  kms_key_id              = var.kms_key_arns.boundary_root
  recovery_window_in_days = 7

  tags = local.tags
}

## Launch templates
resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix   = "${var.project_name}-${each.key}-"
  image_id      = data.aws_ami.node[each.key].id
  instance_type = each.value.instance_type

  # No key_name on purpose: there is no key pair to attach.

  # Top-level security groups and network_interfaces are mutually exclusive.
  vpc_security_group_ids = each.value.public_ip ? null : [aws_security_group.node[each.key].id]

  dynamic "network_interfaces" {
    for_each = each.value.public_ip ? [1] : []
    content {
      device_index                = 0
      associate_public_ip_address = true
      security_groups             = [aws_security_group.node[each.key].id]
      delete_on_termination       = true
    }
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.node[each.key].arn
  }

  # Hop limit 1 keeps bridged containers away from the node's role credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.node[each.key].root_device_name
    ebs {
      volume_size           = each.value.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arns.ebs
      delete_on_termination = true
    }
  }

  dynamic "block_device_mappings" {
    for_each = each.value.data_volume_size == null ? [] : [each.value.data_volume_size]
    content {
      device_name = "/dev/sdf"
      ebs {
        volume_size           = block_device_mappings.value
        volume_type           = "gp3"
        encrypted             = true
        kms_key_id            = var.kms_key_arns.ebs
        delete_on_termination = true
      }
    }
  }

  # Assembled per role: shared prelude, the lock library (vault and boundary
  # only), the role's own script, then any extra_user_data for the group.
  user_data = base64encode(join("\n", compact([
    templatefile("${path.module}/templates/common.sh.tftpl", { role = each.key }),
    contains(local.bootstrap_roles, each.key) ? templatefile("${path.module}/templates/bootstrap_lock.sh.tftpl", { lock_table = local.lock_table }) : "",
    templatefile("${path.module}/templates/${each.key}.sh.tftpl", local.user_data_vars[each.key]),
    each.value.extra_user_data,
    "echo \"==> user-data complete for ${each.key}\"",
  ])))

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags[each.key]
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${var.project_name}-${each.key}" })
  }

  tags = merge(local.tags, { Name = "${var.project_name}-${each.key}-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

## Auto Scaling groups
resource "aws_autoscaling_group" "node" {
  for_each = var.node_groups

  name_prefix         = "${var.project_name}-${each.key}-"
  vpc_zone_identifier = each.value.public_ip ? var.public_subnet_ids : var.private_subnet_ids

  min_size         = each.value.min_size
  max_size         = each.value.max_size
  desired_capacity = each.value.desired_capacity

  health_check_type         = each.value.health_check_type
  health_check_grace_period = each.value.health_check_grace_period
  termination_policies      = ["OldestLaunchTemplate", "OldestInstance"]

  target_group_arns = lookup(var.target_group_arns, each.key, [])

  dynamic "launch_template" {
    for_each = each.value.spot_enabled ? [] : [1]
    content {
      id      = aws_launch_template.node[each.key].id
      version = aws_launch_template.node[each.key].latest_version
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = each.value.spot_enabled ? [1] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = 0
        on_demand_percentage_above_base_capacity = 0
        spot_allocation_strategy                 = "price-capacity-optimized"
      }
      launch_template {
        launch_template_specification {
          launch_template_id = aws_launch_template.node[each.key].id
          version            = aws_launch_template.node[each.key].latest_version
        }
      }
    }
  }

  dynamic "instance_refresh" {
    for_each = var.instance_refresh_enabled ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        # Two of three raft members stay up during a roll.
        min_healthy_percentage = 66
        instance_warmup        = each.value.health_check_grace_period
      }
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags[each.key]
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    # A failover script scales groups with the AWS CLI; Terraform must not undo it.
    ignore_changes = [desired_capacity]

    precondition {
      condition     = !each.value.public_ip || length(var.public_subnet_ids) > 0
      error_message = "public_subnet_ids must not be empty when a node group sets public_ip."
    }
  }

  # Instances must not boot before their permissions exist.
  depends_on = [
    aws_iam_role_policy.autojoin,
    aws_iam_role_policy.vault,
    aws_iam_role_policy.vault_bootstrap,
    aws_iam_role_policy.boundary,
    aws_iam_role_policy.boundary_bootstrap,
    aws_iam_role_policy_attachment.ssm,
  ]
}

data "aws_ami" "ami_ids" {
  region      = var.region
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

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "autojoin" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances", "autoscaling:DescribeAutoScalingGroups"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "vault_unseal" {
  statement {
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [var.kms_key_arns.vault_unseal]
  }
}

data "aws_iam_policy_document" "boundary" {
  statement {
    effect  = "Allow"
    actions = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = [
      var.kms_key_arns.boundary_root,
      var.kms_key_arns.boundary_worker_auth,
      var.kms_key_arns.boundary_recovery,
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.boundary_db.secret_arn]
  }

  dynamic "statement" {
    for_each = var.boundary_db_kms_key_id == null ? [] : [1]
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.boundary_db_kms_key_id]
    }
  }
}

data "aws_iam_policy_document" "bootstrap_vault" {
  count = var.enable_bootstrap_automation ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.bootstrap_lock[0].arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.vault_init[0].arn]
  }
}

data "aws_iam_policy_document" "bootstrap_boundary" {
  count = var.enable_bootstrap_automation ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.bootstrap_lock[0].arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.boundary_init[0].arn]
  }
}

locals {
  ami_by_group = { for k, _ in var.node_groups : k => data.aws_ami.ami_ids[k].id }

  # Ports are properties of the products, not of this deployment.
  ports = {
    consul = {
      server_rpc = 8300
      serf_lan   = 8301
      serf_wan   = 8302
      http       = 8500
      https      = 8501
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
    }
  }

  # Intra-cluster TCP ingress, sourced from the VPC CIDR.
  intra_tcp = {
    nomad_consul_server = [8300, 8301, 8302, 8500, 8501, 8502, 8600, 4646, 4647, 4648]
    nomad_worker        = [8301, 8302, 8500, 8600, 4646, 4647, 4648]
    boundary            = [9200, 9201, 9202, 8301, 8500]
    vault               = [8200, 8201]
  }

  # Gossip needs UDP as well as TCP.
  intra_udp = {
    nomad_consul_server = [8301, 8302, 8600, 4648]
    nomad_worker        = [8301, 8302, 8600, 4648]
    boundary            = [8301]
    vault               = []
  }

  tcp_rules = merge([
    for group, plist in local.intra_tcp : {
      for p in plist : "${group}-tcp-${p}" => { group = group, port = p }
    }
  ]...) # using ... for merging a dynamically generated list of maps.

  udp_rules = merge([
    for group, plist in local.intra_udp : {
      for p in plist : "${group}-udp-${p}" => { group = group, port = p }
    }
  ]...)

  # Services fronted by the internal NLB: record name => target group key.
  internal_services = {
    vault    = { hostname = var.service_hostnames.vault, port = local.ports.vault.api, group = "vault" }
    consul   = { hostname = var.service_hostnames.consul, port = local.ports.consul.http, group = "nomad_consul_server" }
    nomad    = { hostname = var.service_hostnames.nomad, port = local.ports.nomad.http, group = "nomad_consul_server" }
    boundary = { hostname = var.service_hostnames.boundary, port = local.ports.boundary.api, group = "boundary" }
  }

  # Externally exposed: Boundary controller API and worker proxy only.
  external_services = {
    api   = { port = local.ports.boundary.api }
    proxy = { port = local.ports.boundary.proxy }
  }
}

resource "aws_security_group" "node" {
  for_each    = var.node_groups
  name_prefix = "${var.project_name}-${each.key}-"
  description = "Instances in the ${each.key} ASG"
  vpc_id      = var.vpc_id

  tags = merge({
    Name    = "${var.project_name}-${each.key}-sg"
    Project = var.project_name
  }, var.tags)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "intra_tcp" {
  for_each = { for k, v in local.tcp_rules : k => v if contains(keys(var.node_groups), v.group) }

  security_group_id = aws_security_group.node[each.value.group].id
  description       = "TCP ${each.value.port} from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  tags = merge({
    Name    = "${var.project_name}-${each.value.group}-intra-tcp-ingress"
    Project = var.project_name
  }, var.tags)
}

resource "aws_vpc_security_group_ingress_rule" "intra_udp" {
  for_each = { for k, v in local.udp_rules : k => v if contains(keys(var.node_groups), v.group) }

  security_group_id = aws_security_group.node[each.value.group].id
  description       = "UDP ${each.value.port} from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "udp"
  tags = merge({
    Name    = "${var.project_name}-${each.value.group}-intra-udp-ingress"
    Project = var.project_name
  }, var.tags)
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = var.node_groups

  security_group_id = aws_security_group.node[each.key].id
  description       = "All egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = merge({
    Name    = "${var.project_name}-${each.key}-egress-rule"
    Project = var.project_name
  }, var.tags)
}

## Boundary reaches Postgres.
resource "aws_vpc_security_group_ingress_rule" "rds_from_boundary" {
  count = var.create_rds_ingress_rule ? 1 : 0

  security_group_id            = var.boundary_db_security_group_id
  description                  = "Boundary controllers to Postgres"
  referenced_security_group_id = aws_security_group.node["boundary"].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"

  tags = merge({
    Name    = "${var.project_name}-rds-boundary-ingress"
    Project = var.project_name
  }, var.tags)
}


# Security group on the external NLB itself. Client IP preservation is disabled
# on the external target groups, so the instance SG sees the NLB, not the client.
resource "aws_security_group" "nlb_external" {
  name_prefix = "${var.project_name}-nlb-ext-"
  description = "Internet-facing NLB"
  vpc_id      = var.vpc_id

  tags = merge({
    Name    = "${var.project_name}-nlb-ext-sg",
    Project = var.project_name
  }, var.tags)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_external_clients" {
  for_each = {
    for pair in setproduct(keys(local.external_services), var.allowed_client_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = local.external_services[pair[0]].port, cidr = pair[1] }
  }

  security_group_id = aws_security_group.nlb_external.id
  description       = "Boundary ${each.value.port} from ${each.value.cidr}"
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"

  tags = merge({
    Name    = "${var.project_name}-${each.key}-nlb-ext-ingress"
    Project = var.project_name
  }, var.tags)
}

resource "aws_vpc_security_group_egress_rule" "nlb_external_to_targets" {
  security_group_id            = aws_security_group.nlb_external.id
  description                  = "NLB to Boundary instances"
  referenced_security_group_id = aws_security_group.node["boundary"].id
  ip_protocol                  = "-1"
}


## IAM
resource "aws_iam_role" "node" {
  for_each = var.node_groups

  name_prefix        = "${var.project_name}-${each.key}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags = merge({
    Project = var.project_name
    Name    = "${var.project_name}-${each.key}-iam-role"
  }, var.tags)
}

resource "aws_iam_instance_profile" "node" {
  for_each = var.node_groups

  name_prefix = "${var.project_name}-${each.key}-"
  role        = aws_iam_role.node[each.key].name

  lifecycle {
    create_before_destroy = true
  }

  tags = merge({
    Project = var.project_name
    Name    = "${var.project_name}-${each.key}-iam-profile"
  }, var.tags)
}


resource "aws_iam_role_policy" "autojoin" {
  for_each = var.node_groups

  name_prefix = "autojoin-"
  role        = aws_iam_role.node[each.key].id
  policy      = data.aws_iam_policy_document.autojoin.json
}

resource "aws_iam_role_policy" "vault_unseal" {
  count = contains(keys(var.node_groups), "vault") ? 1 : 0

  name_prefix = "vault-unseal-"
  role        = aws_iam_role.node["vault"].id
  policy      = data.aws_iam_policy_document.vault_unseal.json
}

resource "aws_iam_role_policy" "boundary" {
  count = contains(keys(var.node_groups), "boundary") ? 1 : 0

  name_prefix = "boundary-"
  role        = aws_iam_role.node["boundary"].id
  policy      = data.aws_iam_policy_document.boundary.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each = var.enable_ssm ? var.node_groups : {}

  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


resource "aws_iam_role_policy" "bootstrap_boundary" {
  count = var.enable_bootstrap_automation && contains(keys(var.node_groups), "boundary") ? 1 : 0

  name_prefix = "boundary-bootstrap-"
  role        = aws_iam_role.node["boundary"].id
  policy      = data.aws_iam_policy_document.bootstrap_boundary[0].json
}

resource "aws_iam_role_policy" "bootstrap_vault" {
  count = var.enable_bootstrap_automation && contains(keys(var.node_groups), "vault") ? 1 : 0

  name_prefix = "vault-bootstrap-"
  role        = aws_iam_role.node["vault"].id
  policy      = data.aws_iam_policy_document.bootstrap_vault[0].json
}


## Launch Template
resource "aws_launch_template" "node" {
  for_each = var.node_groups

  name_prefix   = "${var.project_name}-${each.key}-"
  image_id      = local.ami_by_group[each.key]
  instance_type = each.value.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = concat(
    [aws_security_group.node[each.key].id],
    lookup(var.additional_security_group_ids, each.key, [])
  )

  iam_instance_profile {
    arn = aws_iam_instance_profile.node[each.key].arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.enable_imdsv2_only ? "required" : "optional"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = each.value.detailed_monitoring
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = each.value.root_volume_size
      volume_type           = each.value.root_volume_type
      encrypted             = true
      kms_key_id            = var.kms_key_arns.ebs
      delete_on_termination = true
    }
  }

  dynamic "block_device_mappings" {
    for_each = each.value.data_volume_size == null ? [] : [each.value]
    content {
      device_name = "/dev/sdf"
      ebs {
        volume_size           = block_device_mappings.value.data_volume_size
        volume_type           = block_device_mappings.value.data_volume_type
        iops                  = block_device_mappings.value.data_volume_iops
        encrypted             = true
        kms_key_id            = var.kms_key_arns.ebs
        delete_on_termination = true
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    role                 = each.key
    project_name         = var.project_name
    consul_datacenter    = var.consul_datacenter
    retry_join_tag_key   = var.retry_join_tag_key
    retry_join_tag_val   = var.project_name
    bootstrap_expect     = var.bootstrap_expect
    private_zone_name    = var.private_zone_name
    service_hostnames    = var.service_hostnames
    vault_kms_key_id     = var.kms_key_arns.vault_unseal
    boundary_kms         = var.kms_key_arns
    ports                = local.ports
    extra                = each.value.extra_user_data
    boundary_db          = var.boundary_db
    boundary_public_addr = aws_lb.external.dns_name
    bootstrap_enabled    = var.enable_bootstrap_automation
    lock_table           = try(aws_dynamodb_table.bootstrap_lock[0].name, "")
    vault_init_secret    = try(aws_secretsmanager_secret.vault_init[0].arn, "")
    boundary_init_secret = try(aws_secretsmanager_secret.boundary_init[0].arn, "")
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, each.value.extra_tags, {
      Name                     = "${var.project_name}-${each.key}"
      Role                     = each.key
      (var.retry_join_tag_key) = var.project_name
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.project_name}-${each.key}", Project = var.project_name })
  }

  lifecycle {
    create_before_destroy = true
  }
}

## Target groups
resource "aws_lb_target_group" "internal" {
  for_each = local.internal_services

  name_prefix          = substr("${each.key}-", 0, 6)
  vpc_id               = var.vpc_id
  port                 = each.value.port
  protocol             = "TCP"
  target_type          = "instance"
  deregistration_delay = var.target_group_deregistration_delay

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${var.project_name}-${each.key}-tg", Project = var.project_name })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "external" {
  for_each = local.external_services

  name_prefix          = substr("bnd${each.key}", 0, 6)
  vpc_id               = var.vpc_id
  port                 = each.value.port
  protocol             = "TCP"
  target_type          = "instance"
  preserve_client_ip   = false
  deregistration_delay = var.target_group_deregistration_delay

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(var.tags, { Name = "${var.project_name}-boundary-${each.key}-ext-tg", Project = var.project_name })

  lifecycle {
    create_before_destroy = true
  }
}

## Auto Scaling groups - ASG
resource "aws_autoscaling_group" "node" {
  for_each = var.node_groups

  name_prefix         = "${var.project_name}-${each.key}-"
  vpc_zone_identifier = var.private_subnet_ids

  min_size         = each.value.min_size
  max_size         = each.value.max_size
  desired_capacity = each.value.desired_capacity

  health_check_type         = each.value.health_check_type
  health_check_grace_period = each.value.health_check_grace_period
  termination_policies      = ["OldestLaunchTemplate", "OldestInstance"]

  target_group_arns = concat(
    [for k, s in local.internal_services : aws_lb_target_group.internal[k].arn if s.group == each.key],
    each.key == "boundary" ? [for k in keys(local.external_services) : aws_lb_target_group.external[k].arn] : []
  )

  dynamic "launch_template" {
    for_each = each.value.spot_enabled ? [] : [1]
    content {
      id      = aws_launch_template.node[each.key].id
      version = aws_launch_template.node[each.key].latest_version
    }
  }

  dynamic "mixed_instances_policy" {
    for_each = each.value.spot_enabled ? [each.value] : []
    content {
      instances_distribution {
        on_demand_base_capacity                  = mixed_instances_policy.value.on_demand_base_count
        on_demand_percentage_above_base_capacity = 0
        spot_allocation_strategy                 = "price-capacity-optimized"
        spot_max_price                           = mixed_instances_policy.value.spot_max_price
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
        min_healthy_percentage = 66
        instance_warmup        = each.value.health_check_grace_period
      }
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, each.value.extra_tags, {
      Name                     = "${var.project_name}-${each.key}"
      Role                     = each.key
      Project                  = var.project_name
      (var.retry_join_tag_key) = var.project_name
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }


  depends_on = [
    aws_iam_role_policy.autojoin,
    aws_iam_role_policy.vault_unseal,
    aws_iam_role_policy.boundary,
    aws_iam_role_policy_attachment.ssm,
  ]
}

## Load balancers
resource "aws_lb" "internal" {
  name_prefix        = "int-"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids

  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_deletion_protection       = var.enable_deletion_protection

  dynamic "access_logs" {
    for_each = coalesce(var.nlb_access_logs.enabled, false) ? [var.nlb_access_logs] : []
    content {
      enabled = true
      bucket  = access_logs.value.bucket
      prefix  = access_logs.value.prefix
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-internal-nlb", Project = var.project_name })
}

resource "aws_lb" "external" {
  name_prefix        = "ext-"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.nlb_external.id]

  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_deletion_protection       = var.enable_deletion_protection

  dynamic "access_logs" {
    for_each = coalesce(var.nlb_access_logs.enabled, false) ? [var.nlb_access_logs] : []
    content {
      enabled = true
      bucket  = access_logs.value.bucket
      prefix  = access_logs.value.prefix
    }
  }

  tags = merge(var.tags, { Name = "${var.project_name}-external-nlb", Project = var.project_name })
}

resource "aws_lb_listener" "internal" {
  for_each = local.internal_services

  load_balancer_arn = aws_lb.internal.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.internal[each.key].arn
  }
}

resource "aws_lb_listener" "external" {
  for_each = local.external_services

  load_balancer_arn = aws_lb.external.arn
  port              = each.value.port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.external[each.key].arn
  }
}

## Private DNS
resource "aws_route53_record" "service" {
  for_each = local.internal_services

  zone_id = var.private_zone_id
  name    = "${each.value.hostname}.${var.private_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.internal.dns_name
    zone_id                = aws_lb.internal.zone_id
    evaluate_target_health = true
  }
}

## Bootstrap Automation
resource "aws_dynamodb_table" "bootstrap_lock" {
  count = var.enable_bootstrap_automation ? 1 : 0

  name         = "${var.project_name}-bootstrap-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockId"

  attribute {
    name = "LockId"
    type = "S"
  }

  tags = merge({ Project = var.project_name }, var.tags)
}

resource "aws_secretsmanager_secret" "vault_init" {
  count = var.enable_bootstrap_automation ? 1 : 0

  name_prefix             = "${var.project_name}/vault/init-"
  description             = "Vault recovery keys and initial root token"
  kms_key_id              = var.kms_key_arns.vault_unseal
  recovery_window_in_days = 7

  tags = merge({ Project = var.project_name }, var.tags)
}

resource "aws_secretsmanager_secret" "boundary_init" {
  count = var.enable_bootstrap_automation ? 1 : 0

  name_prefix             = "${var.project_name}/boundary/init-"
  description             = "Boundary initial admin credentials and auth method ID"
  kms_key_id              = var.kms_key_arns.boundary_root
  recovery_window_in_days = 7

  tags = merge({ Project = var.project_name }, var.tags)
}

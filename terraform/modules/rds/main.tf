locals {
  default_port = {
    postgres = 5432
    mysql    = 3306
    mariadb  = 3306
  }[var.database_engine]

  # Use the explicit port if given, else the engine default.
  db_port               = coalesce(var.database_port, local.default_port)
  self_managed_password = !var.manage_master_user_password
  master_secret_arn = (
    var.manage_master_user_password
    ? aws_db_instance.this.master_user_secret[0].secret_arn
    : aws_secretsmanager_secret.master[0].arn
  )
}

ephemeral "random_password" "master" {
  count = local.self_managed_password ? 1 : 0

  length  = 40
  special = false # safe in URLs, SQL and env files; RDS also rejects / @ " and spaces
}

## Database Subnet group
resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-subnet-group"
  subnet_ids = var.subnet_ids
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## Database security group
resource "aws_security_group" "this" {
  vpc_id      = var.vpc_id
  name        = "${var.project_name}-rds-sg"
  description = "Access to ${var.project_name} RDS"
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## Database ingress rule based on allowed CIDR blocks
resource "aws_vpc_security_group_ingress_rule" "db-cidr" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = each.value
  from_port         = local.db_port
  to_port           = local.db_port
  ip_protocol       = "tcp"
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## Database ingress rule based on Security Groups
resource "aws_vpc_security_group_ingress_rule" "db-sg" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  from_port                    = local.db_port
  to_port                      = local.db_port
  ip_protocol                  = "tcp"
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## Primary Database config
resource "aws_db_instance" "this" {
  identifier     = var.project_name
  engine         = var.database_engine
  engine_version = var.database_engine_version
  instance_class = var.db_instance_class
  port           = local.db_port

  allocated_storage         = var.allocated_storage
  storage_encrypted         = var.storage_encrypted
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project_name}-final-snapshot"

  db_name             = replace("${var.project_name}_primary_rds", "-", "_")
  username            = var.username
  password_wo         = var.manage_master_user_password ? null : ephemeral.random_password.master[0].result
  password_wo_version = var.manage_master_user_password ? null : var.master_password_version

  manage_master_user_password = var.manage_master_user_password ? true : null
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.this.id]

  multi_az            = var.multi_az
  skip_final_snapshot = var.skip_final_snapshot

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  copy_tags_to_snapshot   = true

  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

## Read Replica Database/s Config
resource "aws_db_instance" "replica" {
  count               = var.db_replica_count
  identifier          = "${var.project_name}-replica-${count.index}"
  replicate_source_db = aws_db_instance.this.identifier
  instance_class      = var.db_replica_instance_class
  port                = local.db_port

  vpc_security_group_ids = [aws_security_group.this.id]

  # skip_final_snapshot    = var.skip_final_snapshot
  skip_final_snapshot = true #  RDS does not take final snapshots of read replicas
  deletion_protection = var.deletion_protection

  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

# Password if self managed
resource "aws_secretsmanager_secret" "master" {
  count = local.self_managed_password ? 1 : 0

  name_prefix             = "${var.project_name}/rds/master-"
  description             = "Master credentials for ${var.project_name} RDS (not rotated automatically)"
  kms_key_id              = var.master_secret_kms_key_id
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "master" {
  count = local.self_managed_password ? 1 : 0

  secret_id = aws_secretsmanager_secret.master[0].id

  # Same JSON shape as the RDS-managed secret, so consumers can't tell the difference.
  secret_string_wo = jsonencode({
    username = var.username
    password = ephemeral.random_password.master[0].result
  })
  secret_string_wo_version = var.master_password_version
}

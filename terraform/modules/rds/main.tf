locals {
  default_port = {
    postgres = 5432
    mysql    = 3306
    mariadb  = 3306
  }[var.database_engine]

  # Use the explicit port if given, else the engine default.
  db_port = coalesce(var.database_port, local.default_port)
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
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.project_name}-final-snapshot-${formatdate("YYYY-MM-DD", timestamp())}"

  db_name  = replace("${var.project_name}_primary_rds", "-", "_")
  username = var.username

  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.this.id]

  multi_az            = var.multi_az
  skip_final_snapshot = var.skip_final_snapshot

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
  skip_final_snapshot    = var.skip_final_snapshot
  tags = merge({
    "Project" = var.project_name
  }, var.tags)
}

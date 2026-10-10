data "aws_region" "current" {}

resource "aws_secretsmanager_secret" "this" {
  name_prefix             = var.name_prefix
  description             = var.description
  kms_key_id              = var.kms_key_id
  recovery_window_in_days = var.recovery_window_in_days

  dynamic "replica" {
    for_each = var.replicas
    content {
      region     = replica.value.region
      kms_key_id = replica.value.kms_key_id
    }
  }

  tags = merge({ Project = var.project_name }, var.tags)
}
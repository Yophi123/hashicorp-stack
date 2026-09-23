## KMS Key. Policy is optional(when null, AWS applies its default policy)
resource "aws_kms_key" "this" {
  description             = var.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = var.enable_key_rotation
  policy                  = var.policy

  tags = merge({
    "Project" = var.project_name
    "Alias"   = var.alias
  }, var.tags)
}

## Alias for reference
resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.id
}
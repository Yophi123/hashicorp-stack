# A replica shares the primary's key material and key ID, so anything
# encrypted in one region decrypts in the other.
resource "aws_kms_replica_key" "this" {
  description             = var.description
  primary_key_arn         = var.primary_key_arn
  deletion_window_in_days = var.deletion_window_in_days
  policy                  = var.policy

  tags = merge({
    Project = var.project_name
    Alias   = var.alias
  }, var.tags)
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_replica_key.this.key_id
}
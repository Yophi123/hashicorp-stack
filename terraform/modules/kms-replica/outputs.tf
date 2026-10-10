output "key_id" {
  description = "Key ID. Identical to the primary's."
  value       = aws_kms_replica_key.this.key_id
}

output "key_arn" {
  description = "ARN of the replica key in this region."
  value       = aws_kms_replica_key.this.arn
}

output "alias_name" {
  description = "alias/<alias>."
  value       = aws_kms_alias.this.name
}
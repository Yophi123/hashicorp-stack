output "arn" {
  description = "ARN of the secret in its home region."
  value       = aws_secretsmanager_secret.this.arn
}

output "name" {
  description = "Name of the secret. Identical in every replica region."
  value       = aws_secretsmanager_secret.this.name
}

# A replica's ARN is the primary's with only the region changed.
output "replica_arns" {
  description = "Replica ARN per region."
  value = {
    for r in var.replicas : r.region => replace(
      aws_secretsmanager_secret.this.arn,
      ":${data.aws_region.current.region}:",
      ":${r.region}:"
    )
  }
}
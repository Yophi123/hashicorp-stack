output "address" {
  value       = aws_db_instance.this.address
  description = "Address of database."
}

output "port" {
  value       = aws_db_instance.this.port
  description = "Port of database."
}

output "username" {
  value       = aws_db_instance.this.username
  description = "Username of database."
}

output "dbname" {
  value       = aws_db_instance.this.db_name
  description = "Database name created in managed instance."
}

output "replica_addresses" {
  description = "Addresses of the read replicas, in index order. Empty when db_replica_count is 0."
  value       = aws_db_instance.replica[*].address
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Security group ID for database."
}

output "kms_key_id" {
  value       = aws_db_instance.this.kms_key_id
  description = "KMS Key ID for storage encryption."
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master username/password, in either mode."
  value       = local.master_secret_arn
  depends_on  = [aws_secretsmanager_secret_version.master]
}

output "connection" {
  description = "Host, port, database name and secret ARN for applications to build a connection string."
  value = {
    host       = aws_db_instance.this.address
    port       = aws_db_instance.this.port
    dbname     = aws_db_instance.this.db_name
    secret_arn = local.master_secret_arn
  }
  depends_on = [aws_secretsmanager_secret_version.master]
}

output "master_user_secret_kms_key_id" {
  description = "KMS key encrypting the master secret. Null means the AWS-managed aws/secretsmanager key."
  value = (
    var.manage_master_user_password
    ? aws_db_instance.this.master_user_secret[0].kms_key_id
    : var.master_secret_kms_key_id
  )
}
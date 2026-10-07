variable "project_name" {
  type        = string
  description = "Project name of all associated resources"
}

variable "database_engine" {
  type        = string
  description = "Database engine to run (e.g. postgres, mysql, mariadb)."
  default     = "postgres"

  validation {
    condition     = contains(["postgres", "mysql", "mariadb"], var.database_engine)
    error_message = "database_engine must be one of: postgres, mysql, mariadb."
  }
}

variable "database_engine_version" {
  type        = string
  description = "Version of the engine to deploy."
}

variable "database_port" {
  type        = number
  description = "Database port"
}

variable "db_instance_class" {
  type        = string
  description = "Compute and memory capacity of the instance (e.g. db.t3.micro, db.r6g.large)."
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Size of the database storage in gibibytes (GiB)."
  type        = number
  default     = 20
}

variable "username" {
  description = "Master username for the database. The password is managed by RDS in Secrets Manager."
  type        = string
}

variable "db_replica_instance_class" {
  description = "Instance class for the replica. Can differ from the primary."
  type        = string
  default     = "db.t3.micro"
}

variable "vpc_id" {
  description = "ID of the VPC in which to create the security group that controls access to the instance."
  type        = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs the DB subnet group spans."
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks permitted to connect to the database port."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Source security group IDs permitted to connect to the database port."
  type        = list(string)
  default     = []
}

variable "db_replica_count" {
  description = "Number of read replicas to create. 0 disables replicas."
  type        = number
  default     = 0
}

variable "multi_az" {
  description = "Whether to deploy a standby replica in a second AZ for high availability. Roughly doubles cost; recommended for production."
  type        = bool
  default     = false
}

variable "storage_encrypted" {
  description = "Encrypt the data in the database at rest."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Decide whether a final backup is saved when you delete a database instance."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days to keep automated backups (0-35). Enables point-in-time recovery; 0 disables backups and read replicas."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 0 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 0 and 35."
  }

  validation {
    condition     = var.db_replica_count == 0 || var.backup_retention_period > 0
    error_message = "Read replicas need automated backups on the source; set backup_retention_period > 0."
  }
}

variable "deletion_protection" {
  description = "Block deletion of the instance (and replicas) until this is set back to false and applied."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags merged onto all resources created by this module."
  type        = map(string)
  default     = {}
}


# Password config
variable "manage_master_user_password" {
  type        = bool
  description = <<-EOT
    true:  RDS generates the master password and rotates it in its own
           Secrets Manager secret (every 7 days by default).
    false: Terraform generates it once and stores it in a secret this module
           owns. It never rotates on its own; bump master_password_version.
  EOT
  default     = true
}

variable "master_password_version" {
  type        = number
  description = "Only used when manage_master_user_password = false. Increment to rotate the password."
  default     = 1
}

variable "master_secret_kms_key_id" {
  type        = string
  description = "KMS key for the self-managed secret. Null uses the aws/secretsmanager key."
  default     = null
}
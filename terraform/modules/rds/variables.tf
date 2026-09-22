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

variable "tags" {
  description = "Tags merged onto all resources created by this module."
  type        = map(string)
  default     = {}
}

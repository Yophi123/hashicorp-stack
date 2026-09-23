variable "project_name" {
  description = "value"
  type        = string
}

variable "cluster_name" {
  description = "Name of this cluster (e.g. 'vault', 'consul-server', 'nomad-worker'). Used as the naming prefix for the launch template, ASG, SG, LB, and as the base for tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase, start with a letter, end alphanumeric, and contain only letters, digits, and hyphens."
  }
}


variable "tags" {
  description = "Tags merged onto all resources created by this module."
  type        = map(string)
  default     = {}
}
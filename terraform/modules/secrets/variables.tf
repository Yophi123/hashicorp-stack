variable "project_name" {
  type        = string
  description = "Applied as the Project tag."
}

variable "name_prefix" {
  type        = string
  description = "Prefix of the secret name. Changing it replaces the secret and loses its value."
}

variable "description" {
  type        = string
  description = "What the secret holds."
  default     = null
}

variable "kms_key_id" {
  type        = string
  description = "KMS key that encrypts the secret. Null uses the AWS-managed key."
  default     = null
}

variable "recovery_window_in_days" {
  type        = number
  description = "Days a deleted secret can still be restored."
  default     = 7
}

variable "replicas" {
  type = list(object({
    region     = string
    kms_key_id = optional(string)
  }))
  description = "Regions that get a read-only copy of the secret, kept in sync by Secrets Manager."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags merged with the Project tag."
  default     = {}
}
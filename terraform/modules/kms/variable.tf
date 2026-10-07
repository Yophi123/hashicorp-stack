variable "project_name" {
  type        = string
  description = "Project name of all associated resources"
}

variable "alias" {
  type        = string
  description = "Alias for the KMS key, without the 'alias/' prefix (e.g. 'vault-unseal', 'boundary-root'). Must be unique per region."

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]+$", var.alias))
    error_message = "alias may contain only letters, digits, and the characters / _ -."
  }
}

variable "description" {
  description = "Description of what the key is used for."
  type        = string
  default     = null
}

variable "deletion_window_in_days" {
  description = "Number of days AWS waits before permanently deleting the key after it is scheduled for deletion (7-30)."
  type        = number
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30."
  }
}

variable "enable_key_rotation" {
  description = "Whether AWS automatically rotates the key's cryptographic material once a year."
  type        = bool
  default     = true
}

variable "policy" {
  description = "JSON key policy document. When null, the key uses the AWS default policy granting the account root full access, which callers can extend via IAM."
  type        = string
  default     = null
}

variable "multi_region" {
  description = "Create a multi-region primary key that can be replicated to another region. Cannot be changed after creation."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the KMS key and alias."
  type        = map(string)
  default     = {}
}

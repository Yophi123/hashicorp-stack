variable "project_name" {
  type        = string
  description = "Applied as the Project tag."
}

variable "alias" {
  type        = string
  description = "Alias without the alias/ prefix. Use the same alias as the primary key."
}

variable "primary_key_arn" {
  type        = string
  description = "ARN of the multi-region primary key to replicate."
}

variable "description" {
  type        = string
  description = "Key description."
  default     = null
}

variable "deletion_window_in_days" {
  type        = number
  description = "Waiting period before a scheduled deletion takes effect (7 to 30)."
  default     = 30
}

variable "policy" {
  type        = string
  description = "JSON key policy. Null applies the AWS default policy."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Tags merged with the Project and Alias tags."
  default     = {}
}
variable "project_name" {
  type        = string
  description = "Project name; first part of the bucket name."
}

variable "name" {
  type        = string
  description = "What the bucket holds, e.g. snapshots. Middle part of the bucket name."
}

variable "expiring_prefixes" {
  type        = map(number)
  description = "Key prefix => days after which objects under it are deleted."
  default     = {}
}

variable "force_destroy" {
  type        = bool
  description = "Allow Terraform to delete the bucket while it still holds objects."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource."
  default     = {}
}
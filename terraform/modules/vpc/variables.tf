variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the vpc"
  default     = "10.16.0.0/16"
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "The variable vpc_cidr must contain a valid CIDR block"
  }
}

variable "enable_dns_hostnames" {
  type    = bool
  default = true
}

variable "enable_dns_support" {
  type    = bool
  default = true
}

variable "enable_dhcp_options" {
  type    = bool
  default = true
}

variable "map_public_ip_on_launch" {
  type    = bool
  default = true
}

variable "ipv6_enabled" {
  type    = bool
  default = false
}

variable "tags" {
  description = "Tags merged onto all resources created by this module."
  type        = map(string)
  default     = {}
}
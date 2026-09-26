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

variable "private_zone_name" {
  type        = string
  description = <<-EOT
    Fully qualified private zone name.
    This ends up in TLS SANs and Boundary target addresses, so treat it as
    permanent. Avoid .local (mDNS collisions).
  EOT

  validation {
    condition     = length(split(".", trimsuffix(var.private_zone_name, "."))) >= 2
    error_message = "private_zone_name must be fully qualified, e.g. hashicorp-stack.internal (not a single label)."
  }

  validation {
    condition     = !endswith(trimsuffix(var.private_zone_name, "."), ".local")
    error_message = "Do not use the .local TLD; it collides with mDNS resolvers."
  }
}

variable "records" {
  type = map(object({
    name    = string
    type    = optional(string, "A")
    ttl     = optional(number, 60)
    records = optional(list(string))
    alias = optional(object({
      dns_name               = string
      zone_id                = string
      evaluate_target_health = optional(bool, true)
    }))
  }))
  description = <<-EOT
    Records keyed by an arbitrary label. "name" is relative to the zone
    ("vault", "consul"); use "" for the apex. Set either "alias" (for NLBs)
    or "records" + "ttl", never both.

    Prefer letting the EC2/NLB module create its own records; this is for
    root-level odds and ends.
  EOT

  default = {}
  validation {
    condition = alltrue([
      for r in var.records : (r.alias != null) != (r.records != null)
    ])
    error_message = "Each record must set exactly one of `alias` or `records`."
  }
}

variable "records_force_destroy" {
  type        = bool
  description = "Delete all records when destroying the zone."
  default     = false
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
  type        = bool
  description = "Attach a DHCP option set that adds the private zone to the instance DNS search path."
  default     = true
}

variable "map_public_ip_on_launch" {
  type        = bool
  description = "Auto-assign public IPv4 addresses in the web tier. Off by default: only NLBs belong there."
  default     = false
}

variable "ipv6_enabled" {
  type        = bool
  description = "Assign an Amazon-provided IPv6 /56 to the VPC and a /64 to every subnet. Private tiers egress via an egress-only IGW."
  default     = false
}

variable "tags" {
  description = "Tags merged onto all resources created by this module."
  type        = map(string)
  default     = {}
}
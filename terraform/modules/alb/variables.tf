variable "project_name" {
  type        = string
  description = "Prefix for every resource name."
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource created by this module."
  default     = {}
}

variable "vpc_id" {
  type        = string
  description = "VPC the load balancer and its target groups live in."
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of the VPC. The ALB may only send traffic here."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the ALB, in at least two availability zones."

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB needs subnets in at least two availability zones."
  }
}

variable "public_zone_name" {
  type        = string
  description = "Name of the existing Route 53 public hosted zone, e.g. example.com. Looked up, not created."
}

variable "services" {
  type = map(object({
    hostname       = string
    node_group     = string
    port           = number
    health_port    = optional(number)
    health_path    = string
    health_matcher = optional(string, "200")
  }))
  description = <<-EOT
    Services published on the ALB, routed by host header. Each becomes
    <hostname>.<public_zone_name>. node_group is the ec2 module group whose
    ASG registers with the target group; health_port defaults to port.
  EOT
}

variable "allowed_client_cidrs" {
  type        = list(string)
  description = "Source CIDRs allowed to reach the ALB, i.e. your laptop. Deliberately no default."

  validation {
    condition     = alltrue([for c in var.allowed_client_cidrs : can(cidrnetmask(c))])
    error_message = "Each allowed_client_cidrs entry must be a valid IPv4 CIDR block."
  }
}

variable "deregistration_delay" {
  type        = number
  description = "Seconds a target drains before it is deregistered."
  default     = 30
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Deletion protection on the ALB."
  default     = false
}
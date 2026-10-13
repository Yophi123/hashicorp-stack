variable "region" {
  type        = string
  description = "AWS region for the whole stack."
  default     = "ap-southeast-1"
}

variable "pilot_light_region" {
  type        = string
  description = "AWS region for the whole stack."
  default     = "eu-west-1"
}

variable "allowed_client_cidrs" {
  type        = list(string)
  description = <<-EOT
    Your public IP as a /32. Set it in terraform.tfvars, which should be
    gitignored — this is the only thing standing between the Boundary
    control plane and the open internet.
  EOT
}

variable "hashicorp_stack_domain" {
  type        = string
  description = "Public domain name that will be used"
}

variable "public_apps" {
  type = map(object({
    port        = number
    health_path = optional(string, "/")
  }))
  description = <<-EOT
    Nomad workloads published on both load balancers, keyed by hostname, with
    Route 53 failover between the regions. Each job must listen on the same
    static host port given here.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for a in var.public_apps : a.port >= 20000 && a.port <= 32000])
    error_message = "Ports must be in 20000-32000, the range the worker security group opens to the load balancer."
  }

  validation {
    condition     = !contains(keys(var.public_apps), "boundary")
    error_message = "\"boundary\" is already used as a hostname."
  }
}
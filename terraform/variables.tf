variable "region" {
  type        = string
  description = "AWS region for the whole stack."
  default     = "ap-southeast-1"
}

variable "allowed_client_cidrs" {
  type        = list(string)
  description = <<-EOT
    Your public IP as a /32. Set it in terraform.tfvars, which should be
    gitignored — this is the only thing standing between the Boundary
    control plane and the open internet.
  EOT
}

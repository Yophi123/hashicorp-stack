variable "project_name" {
  type        = string
  description = "Project name, as used by the infrastructure root."
}

variable "region" {
  type        = string
  description = "Region whose Vault is configured: the primary."
}

variable "vault_addr" {
  type        = string
  description = "Vault's address as seen from where Terraform runs, normally a local tunnel."
  default     = "http://127.0.0.1:8200"
}

variable "ssh_login_user" {
  type        = string
  description = "OS user the certificates are valid for."
  default     = "ubuntu"
}

variable "ssh_cert_ttl" {
  type        = string
  description = "Default lifetime of an issued certificate."
  default     = "5m"
}

variable "ssh_cert_max_ttl" {
  type        = string
  description = "Longest lifetime a certificate may be issued for."
  default     = "15m"
}

variable "init_secret_arns" {
  type        = map(string)
  description = "Optional ARNs of the init secrets, keyed vault and boundary. Missing keys are found by name prefix."
  default     = {}
}

variable "boundary_addr" {
  type        = string
  description = "Boundary's public address, https://boundary.<domain>."
}

variable "boundary_org_name" {
  type        = string
  description = "Name of the Boundary org scope."
  default     = "platform"
}

variable "boundary_project_name" {
  type        = string
  description = "Name of the Boundary project scope holding the targets."
  default     = "hashicorp-stack"
}

variable "vault_addr_from_boundary" {
  type        = string
  description = "Vault's address as the Boundary controller reaches it."
  default     = "http://active.vault.service.consul:8200"
}

variable "ssh_session_max_seconds" {
  type        = number
  description = "Longest an SSH session may last. The certificate is only checked at login."
  default     = 3600
}

variable "service_session_max_seconds" {
  type        = number
  description = "Longest a Vault, Nomad or Consul session may last."
  default     = 28800
}
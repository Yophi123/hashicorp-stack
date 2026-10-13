locals {
  init_secrets = toset(["vault", "boundary"])
}

## Scopes
resource "boundary_scope" "org" {
  scope_id                 = "global"
  name                     = var.boundary_org_name
  description              = "The ${var.project_name} platform"
  auto_create_admin_role   = true
  auto_create_default_role = true
}

resource "boundary_scope" "project" {
  scope_id               = boundary_scope.org.id
  name                   = var.boundary_project_name
  description            = "Hosts and services of the platform"
  auto_create_admin_role = true
}

## Vault credential store

# Boundary's own token: orphan, periodic and renewable, as Boundary requires.
# It can only manage itself and issue host-access certificates.
resource "vault_token" "boundary" {
  display_name = "boundary-controller"
  policies     = [vault_policy.boundary_controller.name]
  no_parent    = true
  renewable    = true
  period       = "20m"
}

resource "boundary_credential_store_vault" "vault" {
  name        = "vault"
  description = "Platform Vault, reached by the controller through Consul DNS"
  scope_id    = boundary_scope.project.id
  address     = var.vault_addr_from_boundary
  token       = vault_token.boundary.client_token
}

# Each session gets a new key pair and a short-lived certificate.
resource "boundary_credential_library_vault" "ssh_certificate" {
  name                = "ssh-certificate"
  description         = "One-time SSH key and certificate for ${var.ssh_login_user}"
  credential_store_id = boundary_credential_store_vault.vault.id
  path                = "${vault_mount.ssh.path}/issue/${vault_ssh_secret_backend_role.host_access.name}"
  http_method         = "POST"
  http_request_body   = jsonencode({ valid_principals = var.ssh_login_user })
}

## Targets, addressed by Consul DNS so they follow node replacements

locals {
  ssh_targets = {
    ssh-server = { address = "consul.service.consul", reaches = "the Consul and Nomad server" }
    ssh-vault  = { address = "vault.service.consul", reaches = "the Vault node" }
    ssh-worker = { address = "nomad-client.service.consul", reaches = "a Nomad worker" }
  }

  service_targets = {
    vault  = { address = "active.vault.service.consul", port = 8200 }
    nomad  = { address = "http.nomad.service.consul", port = 4646 }
    consul = { address = "consul.service.consul", port = 8500 }
  }
}

resource "boundary_target" "ssh" {
  for_each = local.ssh_targets

  name                           = each.key
  description                    = "SSH to ${each.value.reaches}, with a certificate brokered from Vault"
  type                           = "tcp"
  scope_id                       = boundary_scope.project.id
  address                        = each.value.address
  default_port                   = 22
  session_max_seconds            = var.ssh_session_max_seconds
  brokered_credential_source_ids = [boundary_credential_library_vault.ssh_certificate.id]
}

resource "boundary_target" "service" {
  for_each = local.service_targets

  name                = each.key
  description         = "${title(each.key)} API and UI"
  type                = "tcp"
  scope_id            = boundary_scope.project.id
  address             = each.value.address
  default_port        = each.value.port
  default_client_port = each.value.port  
  session_max_seconds = var.service_session_max_seconds
}
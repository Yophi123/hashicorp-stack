output "ssh_ca_public_key" {
  description = "Public key of the SSH CA the hosts trust."
  value       = vault_ssh_secret_backend_ca.this.public_key
}

output "ssh_issue_path" {
  description = "Vault path that issues host-access certificates."
  value       = "${vault_mount.ssh.path}/issue/${vault_ssh_secret_backend_role.host_access.name}"
}

output "boundary_scope_ids" {
  description = "Org and project scope ids."
  value = {
    org     = boundary_scope.org.id
    project = boundary_scope.project.id
  }
}

output "boundary_target_ids" {
  description = "Target id per name."
  value = merge(
    { for name, t in boundary_target.ssh : name => t.id },
    { for name, t in boundary_target.service : name => t.id },
  )
}
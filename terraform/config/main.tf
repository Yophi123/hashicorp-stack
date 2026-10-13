## SSH certificate authority

# Mounted at "ssh" because every image's fetch-ssh-ca timer reads
# /v1/ssh/public_key; the hosts start trusting this CA within 5 minutes.
resource "vault_mount" "ssh" {
  path        = "ssh"
  type        = "ssh"
  description = "SSH certificate authority for the platform's hosts"
}

resource "vault_ssh_secret_backend_ca" "this" {
  backend              = vault_mount.ssh.path
  generate_signing_key = true
}

# Issues a fresh key pair and a short-lived certificate for one login user.
resource "vault_ssh_secret_backend_role" "host_access" {
  name    = "host-access"
  backend = vault_mount.ssh.path

  key_type                = "ca"
  allow_user_certificates = true
  allowed_users           = var.ssh_login_user
  default_user            = var.ssh_login_user

  # Modern OpenSSH rejects SHA-1 signatures from an RSA CA.
  algorithm_signer = "rsa-sha2-256"

  default_extensions = { "permit-pty" = "" }
  allowed_extensions = "permit-pty,permit-port-forwarding"

  ttl     = var.ssh_cert_ttl
  max_ttl = var.ssh_cert_max_ttl
}


resource "vault_policy" "boundary_controller" {
  name   = "boundary-controller"
  policy = data.vault_policy_document.boundary_controller.hcl
}
# Platform configuration

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-FFEC6E?style=for-the-badge&logo=vault&logoColor=black)
![Boundary](https://img.shields.io/badge/Boundary-EC585D?style=for-the-badge&logo=hashicorp&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-FF9900?style=for-the-badge)

A second Terraform root that configures the services running on the platform.
The infrastructure root builds the machines; this root configures Vault and
Boundary on them. That includes Vault's SSH certificate authority, Boundary's
scopes and targets, and the link between the two that brokers a one-time SSH
certificate for every session.

## Why a separate root

- **It needs running services.** The Vault and Boundary providers talk to their
  APIs, which only exist after the infrastructure root has applied and both
  services have initialized themselves.
- **Its lifecycle is different.** Infrastructure is replaced through a fresh
  `terraform apply`, while configuration changes go through the APIs without
  replacing a node.
- **Its state is separate.** A full infrastructure destroy leaves this state
  describing services that no longer exist (see [Things to know](#things-to-know)).

## What it configures

### Vault

| Resource | Name | Purpose |
|---|---|---|
| `vault_mount.ssh` | `ssh/` | SSH secrets engine. Mounted at `ssh` because every image's `fetch-ssh-ca` timer reads `/v1/ssh/public_key`. |
| `vault_ssh_secret_backend_ca.this` | | CA signing key generated inside Vault. The private key never leaves Vault. |
| `vault_ssh_secret_backend_role.host_access` | `host-access` | Issues a new key pair and a short-lived certificate for one login user. |
| `vault_policy.boundary_controller` | `boundary-controller` | What Boundary's token may do: manage itself and its leases, and call `ssh/issue/host-access`. |
| `vault_token.boundary` | `boundary-controller` | Boundary's own token: orphan, periodic and renewable, with only that policy. |

The `host-access` role:

| Setting | Value | Why |
|---|---|---|
| `key_type` | `ca` | Certificate-based, not one-time passwords |
| `allowed_users`, `default_user` | `var.ssh_login_user` | Certificates are valid for one OS user only |
| `algorithm_signer` | `rsa-sha2-256` | Modern OpenSSH rejects SHA-1 signatures from an RSA CA |
| `default_extensions` | `permit-pty` | An interactive shell |
| `allowed_extensions` | `permit-pty,permit-port-forwarding` | Nothing else may be requested |
| `ttl` / `max_ttl` | `5m` / `15m` | The certificate only has to outlive the login |

### Boundary

| Resource | Name | Purpose |
|---|---|---|
| `boundary_scope.org` | `var.boundary_org_name` | Org scope for the platform |
| `boundary_scope.project` | `var.boundary_project_name` | Project scope holding every target |
| `boundary_credential_store_vault.vault` | `vault` | Connects Boundary to Vault with its own token |
| `boundary_credential_library_vault.ssh_certificate` | `ssh-certificate` | Calls `ssh/issue/host-access` once per session |
| `boundary_target.ssh` | `ssh-*` | SSH targets, each brokering a certificate |
| `boundary_target.service` | `vault`, `nomad`, `consul` | API and UI targets on fixed local ports |

### Targets

Every target is addressed by a Consul DNS name, so it follows a node when the
node is replaced and needs no AWS credentials.

| Target | Address | Port | Local port | Reaches |
|---|---|---|---|---|
| `ssh-server` | `consul.service.consul` | 22 | random | A Consul and Nomad server |
| `ssh-vault` | `vault.service.consul` | 22 | random | A Vault node |
| `ssh-vault-active` | `active.vault.service.consul` | 22 | random | The active Vault node |
| `ssh-worker` | `nomad-client.service.consul` | 22 | random | A Nomad worker |
| `vault` | `active.vault.service.consul` | 8200 | 8200 | Vault API and UI |
| `nomad` | `http.nomad.service.consul` | 4646 | 4646 | Nomad API and UI |
| `consul` | `consul.service.consul` | 8500 | 8500 | Consul API and UI |

The service targets set `default_client_port`, so their UIs open at the same
local address every time. The SSH targets keep random local ports, so several
SSH sessions can be open at once.

## Secrets

- **The init secrets are read ephemerally.** Vault's root token and Boundary's
  admin password come from Secrets Manager at plan and apply time and never
  reach the state file or the plan.
- **They are found by name prefix,** `<project>/vault/init-` and
  `<project>/boundary/init-`. If the search finds nothing, pass the ARNs in
  `init_secret_arns` instead (see [Apply](#apply)).
- **One secret is in state:** Boundary's Vault token. It can only renew itself
  and issue host-access certificates. Keep `*.tfstate` out of version control.

The `vault_token` resource prints a deprecation warning recommending the
ephemeral version. That's intentional: Boundary stores this token and renews
it for as long as the credential store exists, so a token that disappears
after the run would break the store.

## Prerequisites

| Requirement | Detail |
|---|---|
| Infrastructure | The infrastructure root applied, with Vault and Boundary initialized |
| Port 22 | Open from the Boundary node's security group to the server, worker and Vault groups |
| Terraform | 1.11 or later |
| AWS CLI | Version 2, plus the Session Manager plugin, for the Vault tunnel |
| Boundary CLI | To connect; the Desktop app works for the service targets |
| AWS profile | One that can read both init secrets and start SSM sessions |

## Apply

Vault is never published, so Terraform reaches it through a Systems Manager
port forward. Boundary is reached at its public address.

**1. Open a tunnel to Vault** in one terminal, and leave it running:

```bash
export PROJECT=<project> PRIMARY_REGION=<primary-region> PILOT_REGION=<pilot-region>
source scripts/helpers.sh

aws ssm start-session --region "$PRIMARY_REGION" --target "$(node_id "$PRIMARY_REGION" vault)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8200"],"localPortNumber":["8200"]}'
```

**2. Plan and apply** in a second terminal:

```bash
cd config
terraform init -upgrade

terraform plan \
  -var "project_name=$PROJECT" -var "region=$PRIMARY_REGION" \
  -var "aws_profile=<aws-profile>" -var "boundary_addr=https://boundary.<domain>"
```

Run `terraform apply` with the same variables.

If the plan stops with `reading AWS Secrets Manager Secret Versions ... (<null>)`,
look up the ARNs with the CLI and pass them in:

```bash
arn() {
  AWS_PROFILE=<aws-profile> aws secretsmanager list-secrets --region "$PRIMARY_REGION" \
    --filters Key=name,Values="$PROJECT/$1/init-" \
    --query 'sort_by(SecretList, &CreatedDate)[-1].ARN' --output text
}

terraform plan ... -var "init_secret_arns={vault=\"$(arn vault)\", boundary=\"$(arn boundary)\"}"
```

### Variables

| Name | Default | Description |
|---|---|---|
| `project_name` | required | Project name, as used by the infrastructure root |
| `region` | required | Region whose Vault is configured, normally the primary |
| `boundary_addr` | required | Boundary's public address, `https://boundary.<domain>` |
| `aws_profile` | `null` | AWS CLI profile. Null uses the environment. |
| `init_secret_arns` | `{}` | ARNs of the init secrets, keyed `vault` and `boundary`. Missing keys are found by name prefix. |
| `vault_addr` | `http://127.0.0.1:8200` | Vault's address from where Terraform runs, normally the tunnel |
| `vault_addr_from_boundary` | `http://active.vault.service.consul:8200` | Vault's address as the Boundary controller reaches it |
| `boundary_org_name` | `platform` | Name of the org scope |
| `boundary_project_name` | `infrastructure` | Name of the project scope holding the targets |
| `ssh_login_user` | `ubuntu` | OS user the certificates are valid for |
| `ssh_cert_ttl` | `5m` | Default lifetime of an issued certificate |
| `ssh_cert_max_ttl` | `15m` | Longest lifetime a certificate may be issued for |
| `ssh_session_max_seconds` | `3600` | Longest an SSH session may last |
| `service_session_max_seconds` | `28800` | Longest a Vault, Nomad or Consul session may last |

### Outputs

| Name | Description |
|---|---|
| `ssh_ca_public_key` | Public key of the CA the hosts trust |
| `ssh_issue_path` | Vault path that issues host-access certificates |
| `boundary_scope_ids` | Org and project scope ids |
| `boundary_target_ids` | Target id per name |

## Use it

Log in once per session:

```bash
export BOUNDARY_ADDR=https://boundary.<domain>
boundary authenticate password -auth-method-id <ampw_...> -login-name <login-name>
```

### Vault, Nomad and Consul

```bash
boundary connect -target-name vault  -target-scope-name <project-scope>   # http://127.0.0.1:8200
boundary connect -target-name nomad  -target-scope-name <project-scope>   # http://127.0.0.1:4646
boundary connect -target-name consul -target-scope-name <project-scope>   # http://127.0.0.1:8500
```

In the Desktop app, open `<project-scope>` and select **Connect** on the target.
If the local port is taken, choose another one from the CLI:

```bash
boundary connect -target-name vault -target-scope-name <project-scope> -listen-port <port>
```

### SSH

```bash
./scripts/ssh-host.sh --target ssh-worker --scope <project-scope>
./scripts/ssh-host.sh --target-id <ttcp_...>
```

| Option | Environment | Default |
|---|---|---|
| `--target` | `TARGET` | `ssh-worker` |
| `--scope` | `BOUNDARY_SCOPE` | `infrastructure` |
| `--target-id` | `TARGET_ID` | none; overrides target and scope |
| `--user` | `SSH_USER` | `ubuntu` |

The script asks Boundary to authorize a session. Boundary asks Vault for a new
key pair and certificate and returns them with the session. The script writes
them to a temporary directory, connects, and deletes them when you log out.
Your laptop never needs a Vault token, and no key outlives the session.

## How SSH access works

1. Every host trusts Vault's CA through
   `TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem`, kept current by
   `fetch-ssh-ca`. Instances launch without an EC2 key pair.
2. On each connection, Boundary calls `ssh/issue/host-access` with its own token
   and brokers the result to the user, who must already be authorized for
   that target.
3. The certificate is valid for five minutes and for `ubuntu` only.

The certificate is checked **only at login**. A session that starts with a
valid certificate keeps running after the certificate expires, up to the
target's `session_max_seconds`. It can be cancelled from Boundary at any time:

```bash
boundary sessions list -scope-id <p_...>
boundary sessions cancel -id <s_...>
```

### Community Edition limitation

Boundary Community Edition can broker credentials but cannot inject SSH
certificates; that needs HCP Boundary or Enterprise. So the certificate is
brokered as a generic credential, and `scripts/ssh-host.sh` hands it to `ssh`.

### With several nodes per role

Consul returns every healthy node for a service name, so each SSH session lands
on any healthy node of that role. That's enough for most work, since Raft
commands and logs can be read from any server. Use `ssh-vault-active` to reach
the Vault leader. To reach one specific node, use Systems Manager:

```bash
aws ssm start-session --region <region> --target <instance-id>
```

A node whose services fail their Consul checks drops out of DNS, so it is also
reachable only through Systems Manager.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `(<null>)` from the Secrets Manager ephemeral resource | The name-prefix search found no secret | Check the profile, region and project name, or pass `init_secret_arns` |
| `404 NotFound` from `authorize-session` | No target with that name in that scope | `boundary targets list -recursive`, or use `--target-id` |
| The SSH session hangs before any prompt | Port 22 is blocked from the Boundary node | Add the security group rule in the `ec2` module |
| `Permission denied (publickey)` | The host refused the certificate | On the host: `sudo journalctl -u ssh \| grep -i cert`, and compare `ssh-keygen -lf /etc/ssh/trusted-user-ca-keys.pem` with the certificate's signing CA |
| SSH targets fail with a credential store error | Boundary's Vault token is missing, for example after a restore from an older snapshot | `terraform apply` here again |
| `bind: address already in use` on 8200, 4646 or 8500 | A session to that target is already open | Close it, or pass `-listen-port` |

## Things to know

- **The Vault configuration travels with Vault's data.** The CA, role, policy
  and Boundary's token are part of Vault's snapshots, so a restored Vault keeps
  them, unless the snapshot predates them.
- **Boundary runs only in the primary region.** After a failover, reach the
  pilot light through Systems Manager until Boundary runs there.
- **The providers authenticate with the bootstrap credentials,** Vault's root
  token and Boundary's admin login. Dedicated admin logins replace them in the
  hardening step.
- **After a full `terraform destroy` of the infrastructure,** delete
  `config/terraform.tfstate` before applying again. A new Vault also means a
  new CA, and the hosts pick it up through `fetch-ssh-ca`.
- **Keep the tunnel open** for the whole plan and apply. If it drops, the error
  is a connection refused on `127.0.0.1:8200`.

## Planned

| Part | Adds | Status |
|---|---|---|
| 1. Vault as code | SSH CA, `host-access` role, Boundary's Vault policy | Done |
| 2. Boundary as code | Scopes, Vault credential store, brokered SSH certificates, SSH and service targets | Done |
| 3. Dynamic database credentials | Vault's database engine issuing short-lived PostgreSQL users, brokered by a Boundary database target | Next |
| Later | An AWS host catalog to reach one specific node, and non-root admin logins | After hardening |
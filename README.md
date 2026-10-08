# The HashiCorp Stack

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Packer](https://img.shields.io/badge/Packer-02A8EF?style=for-the-badge&logo=packer&logoColor=white)
![Consul](https://img.shields.io/badge/Consul-F24C53?style=for-the-badge&logo=consul&logoColor=white)
![Nomad](https://img.shields.io/badge/Nomad-00CA8E?style=for-the-badge&logo=nomad&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-FFEC6E?style=for-the-badge&logo=vault&logoColor=black)
![Boundary](https://img.shields.io/badge/Boundary-EC585D?style=for-the-badge&logo=hashicorp&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-FF9900?style=for-the-badge)

A self-hosted platform on AWS built entirely from HashiCorp's community
editions: Consul for service discovery, Nomad for workload scheduling, Vault for
secrets, and Boundary for access. Packer bakes the machine images and Terraform
provisions everything else.

The whole platform has one public entry point. Boundary is the only service
reachable from outside; Vault, Nomad, Consul and every host are reached through
an authenticated Boundary session.

## Architecture

```mermaid
flowchart LR
    user([Operator])

    subgraph AWS["AWS region"]
        subgraph web["web tier, public"]
            alb["Application Load Balancer<br/>HTTPS"]
            bnd["Boundary<br/>controller and worker"]
        end
        subgraph app["app tier, private"]
            srv["Consul server<br/>Nomad server"]
            vault["Vault"]
            wrk["Nomad worker<br/>Docker"]
        end
        subgraph db["db tier, private"]
            rds[("PostgreSQL")]
        end
        kms{{"KMS"}}
    end

    user -->|"UI and API"| alb
    alb --> bnd
    user -->|"session traffic"| bnd
    bnd -->|"proxied sessions"| srv
    bnd -->|"proxied sessions"| vault
    bnd -->|"proxied sessions"| wrk
    bnd --> rds
    vault -.->|"auto-unseal"| kms
    bnd -.->|"key wrapping"| kms
```

| Node group | Runs | Tier | Nodes today |
|---|---|---|---|
| `nomad_consul_server` | Consul server, Nomad server | app | 1 |
| `vault` | Vault with integrated Raft storage, Consul client | app | 1 |
| `nomad_worker` | Nomad client, Docker, Consul client | app | 1 |
| `boundary` | Boundary controller and worker, Consul client | web | 1 |

Each group is an Auto Scaling group, sized for an account limited to 8 vCPU.
The modules accept 1, 3 or 5 servers per Raft group, so scaling up is a change
of numbers, not of design.

## Design principles

- **One way in.** Only Boundary is published, over HTTPS, to an allow-list of
  client addresses.
- **No SSH key pairs.** Instances launch without one, and port 22 accepts
  connections only from the Boundary worker. Systems Manager is the break-glass
  path.
- **Immutable images.** Software is installed at image build time. Instances
  only receive configuration at boot and never install packages.
- **Discovery through Consul.** Nodes find their cluster by cloud auto-join tags
  and find each other's services as `*.service.consul`. There is no internal
  load balancer.
- **No secrets in Terraform state.** The database password and the Vault and
  Boundary bootstrap credentials are generated outside state and stored in
  Secrets Manager.
- **One KMS key per purpose.** Vault's seal and Boundary's three key roles each
  have their own key.

## Prerequisites

| Requirement | Detail |
|---|---|
| Terraform | 1.11 or later |
| Packer | With the `amazon` plugin, `~> 1.8` |
| AWS CLI | Version 2, plus the Session Manager plugin |
| Boundary CLI | Or the Boundary Desktop app, to open sessions |
| AWS profiles | `packer` for image builds and `terraform` for provisioning |
| Domain | A Route 53 public hosted zone that already exists |
| Quota | 8 on-demand vCPU in the region; the four nodes use all of it |

## 1. Build the images

Four images, each from Ubuntu 26.04 on amd64. Terraform selects the newest
available image for each role by its `Role` tag.

| Image | `Role` tag | Installed |
|---|---|---|
| Control plane | `nomad-consul-control-plane` | Consul, Nomad |
| Worker | `nomad-consul-client-plane` | Consul, Nomad, Docker |
| Vault | `vault-control-plane` | Vault, Consul |
| Boundary | `boundary-plane` | Boundary, Consul, PostgreSQL client |

Every image also carries the AWS CLI and `jq`, `.consul` DNS forwarding to the
local Consul agent, and trust for Vault's SSH certificate authority. Services
are installed but left disabled, so nothing starts before its configuration is
written at boot.

From each image's directory:

```bash
packer init .
packer build .
```

A build launches a temporary instance, so it needs free vCPU quota. Build the
images before the first `terraform apply`, or after removing the Auto Scaling
groups (see Operations).

## 2. Provision the platform

Create `terraform.tfvars` in the Terraform root. Keep it out of version control.

```hcl
hashicorp_stack_domain = "example.com"
allowed_client_cidrs   = ["203.0.113.10/32"]
```

```bash
terraform init
terraform apply
```

### Variables

| Name | Default | Description |
|---|---|---|
| `region` | `ap-southeast-1` | AWS region for the stack. Also used as the Consul datacenter and Nomad region name. |
| `hashicorp_stack_domain` | required | Public hosted zone. Boundary is published at `boundary.<domain>`. |
| `allowed_client_cidrs` | required | Addresses allowed to reach the load balancer and the Boundary worker. |

### Modules

| Module | Purpose |
|---|---|
| `vpc` | Three-tier network across three zones, NAT gateway, private hosted zone |
| `kms` | One customer-managed key per purpose; called four times |
| `rds` | PostgreSQL for Boundary, with the password kept out of state |
| `alb` | Public load balancer, wildcard certificate and DNS records |
| `ec2` | The four node groups, their IAM roles and first-boot initialization |

Each module has its own README.

### Outputs

| Name | Description |
|---|---|
| `boundary_url` | Boundary UI and API address. |
| `boundary_init_secret_arn` | Secret holding Boundary's initial admin credentials. |
| `vault_init_secret_arn` | Secret holding Vault's recovery keys and initial root token. |
| `autoscaling_group_names` | Auto Scaling group name per node group. |
| `iam_role_arns` | Instance role ARN per node group. |
| `ami_ids` | Images found for this project. |
| `hashicorp_stack_domain` | The public zone in use. |

Vault and Boundary initialize themselves on first boot. Allow about five
minutes after the apply finishes before logging in.

## 3. Log in

```bash
export BOUNDARY_ADDR="$(terraform output -raw boundary_url)"

aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw boundary_init_secret_arn)" \
  --query SecretString --output text | jq '.auth_method'

boundary authenticate password -auth-method-id <ampw_...> -login-name admin
```

Vault, Nomad and Consul are registered in Boundary as TCP targets addressed by
their Consul DNS names. Open a session, then browse to the local port:

```bash
boundary connect -target-id <ttcp_...>
```

| Target | Address | Local URL |
|---|---|---|
| Vault | `active.vault.service.consul:8200` | `http://127.0.0.1:8200` |
| Nomad | `http.nomad.service.consul:4646` | `http://127.0.0.1:4646` |
| Consul | `consul.service.consul:8500` | `http://127.0.0.1:8500` |

## 4. Verify

From a shell on the control plane node (`aws ssm start-session --target <id>`):

```bash
consul members          # four nodes, all alive
nomad server members    # one server, leader
nomad node status       # one client, ready
```

On the Vault node, `vault status` should report `Initialized true` and
`Sealed false`.

## Operations

**Rebuilding the images.** Remove only the Auto Scaling groups. Destroying the
whole `ec2` module would delete the secret holding Boundary's admin credentials
while its database stays initialized.

```bash
terraform destroy -target='module.ec2.aws_autoscaling_group.node'
# build the images, then reset Vault's init record, because its data is gone:
aws dynamodb delete-item --table-name hashicorp-stack-bootstrap-lock \
  --key '{"LockId":{"S":"vault-init"}}'
terraform apply -replace='module.ec2.aws_secretsmanager_secret.vault_init[0]'
```

Boundary resumes against its existing database with the same login. Vault
initializes fresh with a new root token.

**Changing a template or image.** Running instances keep the configuration they
booted with. Replace an instance to pick up a change.

**Tearing down.** `terraform destroy` removes everything. KMS keys enter a
30-day deletion window, and the database is deleted without a final snapshot in
the current evaluation settings.

## Status

Working today, in one region:

- All four services running, joined and initialized automatically
- Boundary published over HTTPS, with Vault, Nomad and Consul reachable only
  through it
- Docker workloads scheduled by Nomad and registered in Consul

Planned next:

- Vault snapshots and restore on boot, so a single Vault node survives
  replacement
- Vault configured as code: SSH certificate authority and dynamic secrets
- Boundary scopes, targets and credential brokering as code
- ACLs, gossip encryption and TLS for Consul and Nomad
- A second region as a pilot-light recovery site, with Consul and Nomad
  federated across the two
- Three nodes per Raft group when quota allows

## Known limitations

- Single nodes throughout, so there is no high availability yet.
- Vault's data is lost when its only node is replaced.
- Consul and Nomad run without ACLs or encryption; Boundary is the only control
  in front of them.
- Terraform state is local. An S3 backend block is present but commented out.

## Command reference

Commands marked **laptop** run from your machine with the AWS and Boundary
CLIs. Commands marked **node** run in a shell on an instance.

### Getting onto a node

```bash
# laptop: list the nodes, with their role, image and launch time
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=hashicorp-stack" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Role`]|[0].Value, InstanceId, PrivateIpAddress, ImageId, LaunchTime]' \
  --output table

# laptop: open a shell (roles: nomad_consul_server, nomad_worker, vault, boundary)
aws ssm start-session --target <instance-id>

# laptop: forward a port without Boundary, as a break-glass path
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8200"],"localPortNumber":["8200"]}'
```

### Service state on every node at once

```bash
# laptop: run one command on all nodes and print each node's answer
CMD_ID=$(aws ssm send-command \
  --document-name AWS-RunShellScript \
  --targets "Key=tag:Project,Values=hashicorp-stack" \
  --parameters 'commands=["cloud-init status; systemctl list-units --no-legend --plain consul.service nomad.service vault.service boundary.service"]' \
  --query Command.CommandId --output text)

sleep 5
aws ssm list-command-invocations --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[].[InstanceId, CommandPlugins[0].Output]' --output text
```

### Boot and service logs (node)

```bash
cloud-init status                           # done = user data finished
sudo tail -n 30 /var/log/user-data.log      # ends with "user-data complete for <role>"

systemctl is-active consul nomad vault boundary
systemctl status <service> --no-pager
sudo journalctl -u <service> --no-pager -n 40    # --no-pager shows full lines
sudo journalctl -fu <service>                    # follow live

systemctl list-timers --all                 # vault-snapshot and fetch-ssh-ca
```

| Unit | Found on | What it is |
|---|---|---|
| `consul` | every node | Consul agent |
| `nomad` | control plane, worker | Nomad agent |
| `vault` | vault | Vault server |
| `vault-bootstrap` | vault | One-time init, or restore from the latest snapshot |
| `vault-snapshot` | vault | Snapshot to S3, run by a timer |
| `boundary` | boundary | Controller and worker |
| `boundary-bootstrap` | boundary | One-time database init |
| `fetch-ssh-ca` | every node | Fetches Vault's SSH CA public key, run by a timer |

### Consul (node)

```bash
consul members                                    # every node, all alive
consul catalog services                           # consul, nomad, nomad-client, vault
consul operator raft list-peers                   # servers and the leader
curl -s http://127.0.0.1:8500/v1/status/leader    # leader address

resolvectl query consul.service.consul            # .consul names resolve through the local agent
resolvectl query active.vault.service.consul
resolvectl query http.nomad.service.consul
```

### Nomad

```bash
# node (control plane)
nomad server members            # servers, leader and region
nomad node status               # clients and whether they are ready

# node (worker)
nomad node status -self | grep -i docker    # the Docker driver is healthy

# laptop, with a Boundary session open to the Nomad target
export NOMAD_ADDR=http://127.0.0.1:4646
nomad job run whoami.nomad.hcl
nomad job status whoami
nomad alloc status <alloc-id>   # where it runs and on which port
nomad alloc logs <alloc-id>
nomad job stop whoami
```

### Boundary

```bash
# laptop: log in
export BOUNDARY_ADDR="$(terraform output -raw boundary_url)"

aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw boundary_init_secret_arn)" \
  --query SecretString --output text | jq '.auth_method'

boundary auth-methods list                 # find the ampw_ id; works before logging in
boundary authenticate password -auth-method-id <ampw_...> -login-name admin

# laptop: use it
boundary targets list -recursive           # find the ttcp_ ids
boundary connect -target-id <ttcp_...>     # opens a local port; stop it to end the session
boundary sessions list -recursive

# node (boundary): health
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9203/health    # 200
```

```bash
# laptop: is the public path working end to end?
curl -s -o /dev/null -w '%{http_code}\n' "$(terraform output -raw boundary_url)"
```

| Result | Meaning |
|---|---|
| 200 | DNS, certificate, load balancer and Boundary all working |
| 503 | Load balancer is up but Boundary is unhealthy |
| 404 | The hostname did not match a routing rule |
| Timeout | Your address is not in `allowed_client_cidrs` |

### Vault

Day to day, from a laptop with a Boundary session open to the Vault target:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw vault_init_secret_arn)" \
  --query SecretString --output text | jq -r '.root_token')"

vault status                    # Initialized true, Sealed false
vault token lookup              # policies [root]
vault operator raft list-peers  # cluster members
vault secrets list              # mounted secrets engines
vault auth list                 # enabled auth methods

vault secrets enable -path=secret kv-v2
vault kv put secret/canary value=before-restore
vault kv get secret/canary
```

What the bootstrap configured for snapshots, for inspection:

```bash
vault policy read snapshot
vault read auth/aws/role/snapshot
```

Snapshots:

```bash
# node (vault): take one now and check it
sudo systemctl start vault-snapshot
sudo journalctl -u vault-snapshot --no-pager | tail -n 5    # "snapshot <timestamp> saved"

# node (vault): what the last boot did, init or restore
sudo journalctl -u vault-bootstrap --no-pager | tail -n 20

# laptop: what is in the bucket
aws s3 ls "s3://$(terraform output -raw snapshot_bucket)/vault/" --recursive
```

Commands the automation runs for you, listed so the scripts are not a black box:

| Command | When |
|---|---|
| `vault operator init -recovery-shares=5 -recovery-threshold=3` | Once, on the first node of a new cluster |
| `vault auth enable aws`, `vault policy write snapshot`, `vault write auth/aws/role/snapshot` | Once, right after init |
| `vault login -method=aws -token-only role=snapshot` | Every snapshot; the node logs in with its IAM role |
| `vault operator raft snapshot save` | Every snapshot |
| `vault operator raft snapshot restore -force` | On a new node, when a snapshot exists and no cluster does |
| `vault operator raft autopilot set-config` | After init, on clusters of three or more |

### Bootstrap lock (laptop)

```bash
# who holds a lock, and in what state
aws dynamodb get-item --region ap-southeast-1 \
  --table-name hashicorp-stack-bootstrap-lock \
  --key '{"LockId":{"S":"vault-init"}}'

# clear a lock (ids: vault-init, vault-restore, boundary-db-init)
aws dynamodb delete-item --region ap-southeast-1 \
  --table-name hashicorp-stack-bootstrap-lock \
  --key '{"LockId":{"S":"vault-init"}}'
```

### Replacing a node (laptop)

```bash
# the Auto Scaling group launches a replacement from the current launch template
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <instance-id> --no-should-decrement-desired-capacity

# confirm which images exist and which is newest for each role
aws ec2 describe-images --owners self \
  --filters "Name=tag:BuiltBy,Values=packer" \
  --query 'sort_by(Images, &CreationDate)[].[Tags[?Key==`Role`]|[0].Value, ImageId, CreationDate]' \
  --output table
```

### DNS (laptop)

```bash
dig +short boundary.<domain>              # the address record
dig +short NS <domain>                    # the zone's name servers
dig boundary.<domain> @<name server>      # ask Route 53 directly; read the status line
dig +short boundary.<domain> @1.1.1.1     # rule out a stale local cache
```
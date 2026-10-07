# EC2 module

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Consul](https://img.shields.io/badge/Consul-F24C53?style=for-the-badge&logo=consul&logoColor=white)
![Nomad](https://img.shields.io/badge/Nomad-00CA8E?style=for-the-badge&logo=nomad&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-FFEC6E?style=for-the-badge&logo=vault&logoColor=black)
![Boundary](https://img.shields.io/badge/Boundary-EC585D?style=for-the-badge&logo=hashicorp&logoColor=white)
![Amazon EC2](https://img.shields.io/badge/Amazon%20EC2-FF9900?style=for-the-badge)
![Auto Scaling](https://img.shields.io/badge/Auto%20Scaling-FF9900?style=for-the-badge)
![IAM](https://img.shields.io/badge/IAM-DD344C?style=for-the-badge)
![DynamoDB](https://img.shields.io/badge/DynamoDB-4053D6?style=for-the-badge)
![Secrets Manager](https://img.shields.io/badge/Secrets%20Manager-DD344C?style=for-the-badge)

Runs the compute for the HashiCorp stack: one Auto Scaling group per role, each
launched from a Packer-built AMI and configured at boot by a user data template.
Load balancing lives in the `alb` module; this module only receives target group
ARNs.

## Node groups

| Key | Runs | AMI `Role` tag | Subnets |
|---|---|---|---|
| `nomad_consul_server` | Consul server, Nomad server | `nomad-consul-control-plane` | private |
| `nomad_worker` | Consul client, Nomad client, Docker | `nomad-consul-client-plane` | private |
| `vault` | Consul client, Vault (integrated Raft, KMS auto-unseal) | `vault-control-plane` | private |
| `boundary` | Consul client, Boundary controller and worker | `boundary-plane` | public |

Keys are fixed. Leave one out of `node_groups` to skip that group.

## What it creates

- A security group, IAM role and instance profile per node group
- A launch template and Auto Scaling group per node group
- Role-specific IAM policies: cloud auto-join for all, KMS for Vault and Boundary,
  database secret access for Boundary
- A DynamoDB lock table and two Secrets Manager secrets for first-boot
  initialization of Vault and Boundary (optional)

## Design decisions

- **No SSH key pairs.** There is no `key_name` input. Port 22 is open only from
  the Boundary security group; SSM is the break-glass path.
- **IMDSv2 required, hop limit 1.** Containers on the workers cannot read the
  node's IAM credentials.
- **Cloud auto-join by tag.** Each instance is tagged
  `<retry_join_tag_key> = <project_name>-<node_group>`. Consul, Nomad and Vault
  find their peers through that tag, so no addresses are hardcoded.
- **Consul agent on every node.** Services are discovered as `*.service.consul`
  instead of through an internal load balancer.
- **Initialize exactly once.** `vault operator init` and `boundary database init`
  run automatically on first boot. A DynamoDB conditional write elects the single
  node that performs each one, and the output is stored in Secrets Manager.
- **`desired_capacity` is ignored after creation**, so a failover script can
  scale groups with the AWS CLI without Terraform reverting it.
- **Federation is designed in but off by default.** The `federation` input opens
  the cross-region ports and adds the WAN join settings.

## Usage

```hcl
module "ec2" {
  source = "./modules/ec2"

  project_name = var.project_name

  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  consul_datacenter = var.region
  nomad_region      = var.region

  kms_key_arns = {
    vault_unseal         = module.kms_vault_unseal.key_arn
    boundary_root        = module.kms_boundary_root.key_arn
    boundary_worker_auth = module.kms_boundary_worker.key_arn
    boundary_recovery    = module.kms_boundary_recovery.key_arn
  }

  boundary_db                   = module.rds.connection
  boundary_db_security_group_id = module.rds.security_group_id

  target_group_arns    = module.alb.target_group_arns
  allowed_client_cidrs = var.allowed_client_cidrs
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Resource name prefix and auto-join scope. Max 16 characters. |
| `tags` | `map(string)` | `{}` | Tags merged onto every resource. |
| `vpc_id` | `string` | required | VPC the instances launch into. |
| `vpc_cidr` | `string` | required | Source for intra-cluster security group rules. |
| `private_subnet_ids` | `list(string)` | required | Subnets for groups without `public_ip`. |
| `public_subnet_ids` | `list(string)` | `[]` | Subnets for groups with `public_ip`. |
| `ami_owners` | `list(string)` | `["self"]` | Accounts that own the Packer AMIs. |
| `ami_role_tags` | `object` | see table above | `Role` tag value per node group. |
| `node_groups` | `map(object)` | one node per group | Size, instance type and disk settings per group. |
| `instance_refresh_enabled` | `bool` | `false` | Roll instances when a launch template changes. |
| `consul_datacenter` | `string` | required | Consul datacenter name. Unique per region. |
| `nomad_region` | `string` | required | Nomad region name. Unique per region; cannot change after bootstrap. |
| `retry_join_tag_key` | `string` | `"HashiStackJoin"` | Tag key used for cloud auto-join. |
| `federation` | `object` | `{}` | Peer CIDRs, peer AWS regions, primary datacenter and authoritative region. |
| `kms_key_arns` | `object` | `{}` | Vault unseal key and the three Boundary keys. `ebs` is optional. |
| `boundary_db` | `object` | `null` | Postgres host, port, database name and secret ARN. |
| `boundary_db_kms_key_id` | `string` | `null` | KMS key of the database secret, if customer-managed. |
| `boundary_db_security_group_id` | `string` | `null` | RDS security group to open to Boundary. |
| `create_rds_ingress_rule` | `bool` | `true` | Add the 5432 rule to the RDS security group. |
| `target_group_arns` | `map(list(string))` | `{}` | ALB target groups per node group. |
| `allowed_client_cidrs` | `list(string)` | required | CIDRs allowed to reach the Boundary worker proxy port. |
| `enable_ssm` | `bool` | `true` | Attach the SSM managed policy to every role. |
| `enable_bootstrap_automation` | `bool` | `true` | Initialize Vault and Boundary automatically on first boot. |

Inputs marked `null` or `{}` by default become required when the node group that
uses them exists. This is enforced with preconditions.

## Outputs

| Name | Description |
|---|---|
| `security_group_ids` | Security group ID per node group. |
| `iam_role_arns` | Instance role ARN per node group. |
| `iam_role_names` | Instance role name per node group. |
| `autoscaling_group_names` | ASG name per node group. |
| `ami_ids` | AMI each node group launches from. |
| `join_tag` | Auto-join tag key and the value per node group. |
| `ports` | Port numbers for every product. |
| `vault_init_secret_arn` | Secret holding Vault's recovery keys and initial root token. |
| `boundary_init_secret_arn` | Secret holding Boundary's initial admin credentials. |

## Templates

| File | Used by | Purpose |
|---|---|---|
| `common.sh.tftpl` | all | Instance facts, data volume mount, `start_service` helper. |
| `bootstrap_lock.sh.tftpl` | vault, boundary | DynamoDB lock library used by the init jobs. |
| `nomad_consul_server.sh.tftpl` | nomad_consul_server | Consul and Nomad server configuration. |
| `nomad_worker.sh.tftpl` | nomad_worker | Consul client and Nomad client configuration. |
| `vault.sh.tftpl` | vault | Consul client, Vault configuration, one-time init. |
| `boundary.sh.tftpl` | boundary | Consul client, Boundary configuration, one-time database init. |

## AMI requirements

The images must have the product binaries installed with their services
**disabled** and default config files removed, the AWS CLI and `jq` available,
`.consul` DNS forwarding configured, and the tags `Role` and `BuiltBy = packer`.
See `packer/`.

## Operating notes

- **Resizing a Raft group:** change `min_size` and `desired_capacity` together,
  and only between 1, 3 and 5. New servers join automatically.
- **Changing an image or template:** with instance refresh off, running instances
  keep their old configuration until they are replaced.
- **Rebuilding compute:** destroy only the Auto Scaling groups. Destroying the
  whole module deletes the init secrets while Boundary's database stays
  initialized.

## Known limitations

- A single Vault node keeps its data on an instance volume. Replacing it loses
  that data until snapshot restore on boot is implemented.
- Consul and Nomad run without ACLs, gossip encryption or TLS at this stage.

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.3 |
| AWS provider | ~> 6.0 |
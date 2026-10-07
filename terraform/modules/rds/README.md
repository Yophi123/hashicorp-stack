# RDS module

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Amazon RDS](https://img.shields.io/badge/Amazon%20RDS-527FFF?style=for-the-badge)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white)
![Secrets Manager](https://img.shields.io/badge/Secrets%20Manager-DD344C?style=for-the-badge)

Provisions an Amazon RDS instance with its subnet group and security group, and
optional read replicas. In this platform it holds Boundary's controller state:
scopes, targets, sessions and KMS-wrapped credentials.

Its defining property is that the master password never reaches Terraform state
or plan output, in either of its two password modes. Consumers receive a secret
ARN and read the password at boot through their instance role.

## What it creates

- A DB subnet group over the subnets passed in, intended for the `db` tier
- A security group with no ingress until a caller adds some
- Optional ingress rules per allowed CIDR and per allowed security group
- The primary instance, encrypted at rest and not publicly accessible
- Zero or more same-region read replicas
- In self-managed password mode only: a Secrets Manager secret and its value

## Password modes

| | RDS-managed (default) | Self-managed |
|---|---|---|
| `manage_master_user_password` | `true` | `false` |
| Who generates it | RDS | Terraform, as an ephemeral value |
| Where it lives | A secret that RDS owns | A secret this module owns |
| Rotation | Automatic, every 7 days by default | Only when `master_password_version` is incremented |
| Secret's KMS key | AWS-managed | `master_secret_kms_key_id`, or AWS-managed if null |
| In Terraform state | No | No; written through write-only arguments |

Both modes store the same JSON shape, `{ username, password }`, so consumers
cannot tell them apart. `master_user_secret_arn` and `connection.secret_arn`
point at whichever secret is in use.

## Design decisions

- **No password in state.** RDS-managed mode hands Terraform only an ARN.
  Self-managed mode uses an ephemeral random password and write-only arguments,
  so the value passes through an apply without being stored.
- **Ingress is owned by the consumer.** The module exposes `security_group_id`
  and callers attach their own rule. The database knows nothing about Boundary,
  and the `rds` and `ec2` modules do not depend on each other in a loop.
- **Engine-agnostic, PostgreSQL first.** The port falls back to the engine's
  default, so MySQL and MariaDB work. Boundary itself requires PostgreSQL.
- **Stable final snapshot name.** `<project_name>-final-snapshot` never causes a
  plan diff. A leftover snapshot with that name from an earlier teardown must be
  deleted before destroying again.
- **Safe defaults, relaxed by the caller.** Deletion protection is on and the
  final snapshot is kept unless the root module says otherwise.

## Usage

```hcl
module "rds" {
  source = "./modules/rds"

  project_name            = var.project_name
  database_engine         = "postgres"
  database_engine_version = "18.3"
  database_port           = 5432
  db_instance_class       = "db.t3.micro"
  username                = "hashicorp_user"

  vpc_id     = module.networking.vpc-id
  subnet_ids = module.networking.db_subnet_ids

  # Evaluation posture: allows a clean terraform destroy. Flip both for production.
  skip_final_snapshot = true
  deletion_protection = false
}

module "ec2" {
  # ...
  boundary_db                   = module.rds.connection
  boundary_db_security_group_id = module.rds.security_group_id
}
```

To grant access from inside this module instead:

```hcl
  allowed_security_group_ids = [aws_security_group.app.id]
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Instance identifier, name prefix, and basis of the database name. |
| `database_engine` | `string` | `"postgres"` | `postgres`, `mysql` or `mariadb`. |
| `database_engine_version` | `string` | required | Engine version, for example `"18.3"`. |
| `database_port` | `number` | required | Listener port. `null` uses the engine default. |
| `db_instance_class` | `string` | `"db.t3.micro"` | Primary instance class. |
| `allocated_storage` | `number` | `20` | Storage in GiB. |
| `storage_encrypted` | `bool` | `true` | Encrypt storage at rest with the AWS-managed RDS key. |
| `username` | `string` | required | Master username. |
| `manage_master_user_password` | `bool` | `true` | Password mode; see the table above. |
| `master_password_version` | `number` | `1` | Self-managed mode only. Increment to rotate. |
| `master_secret_kms_key_id` | `string` | `null` | Self-managed mode only. KMS key for the secret. |
| `vpc_id` | `string` | required | VPC for the security group. |
| `subnet_ids` | `list(string)` | required | Subnets for the DB subnet group. |
| `allowed_cidr_blocks` | `list(string)` | `[]` | CIDRs allowed on the database port. |
| `allowed_security_group_ids` | `list(string)` | `[]` | Security groups allowed on the database port. |
| `multi_az` | `bool` | `false` | Standby in a second zone with automatic failover. |
| `db_replica_count` | `number` | `0` | Number of same-region read replicas. |
| `db_replica_instance_class` | `string` | `"db.t3.micro"` | Replica instance class. |
| `backup_retention_period` | `number` | `7` | Days of automated backups (0 to 35). Must be above 0 with replicas. |
| `skip_final_snapshot` | `bool` | `false` | Skip the final snapshot on destroy. |
| `deletion_protection` | `bool` | `true` | Block deletion of the primary and replicas. |
| `tags` | `map(string)` | `{}` | Tags merged onto every resource. |

## Outputs

| Name | Description |
|---|---|
| `connection` | `{ host, port, dbname, secret_arn }`: everything needed to build a connection string, password excluded. |
| `address` | Primary endpoint hostname. |
| `port` | Listener port. |
| `username` | Master username. |
| `dbname` | Initial database name: `project_name` with hyphens as underscores, plus `_primary_rds`. |
| `security_group_id` | RDS security group, for consumers to add ingress to. |
| `master_user_secret_arn` | Secret holding the master credentials, in either mode. |
| `master_user_secret_kms_key_id` | KMS key encrypting that secret. Null means the AWS-managed key. |
| `kms_key_id` | KMS key used for storage encryption. |
| `replica_addresses` | Replica endpoints in index order, or an empty list. |

## Disaster recovery

The platform's recovery plan rebuilds Boundary's configuration with Terraform
against a new database in the second region, so nothing here is replicated.
The alternatives, if Boundary's data ever needs to survive a regional failure:

| Strategy | Data loss | Recovery time | Notes |
|---|---|---|---|
| Cross-region automated backup replication | minutes | a restore, 15 to 30 minutes | Nothing running in the second region. |
| Cross-region read replica | seconds | a promotion, about 5 minutes | Not supported by this module's replica resource. |
| Manual snapshot copy | since the last snapshot | a restore | Break-glass fallback. |

Either of the first two also requires the `boundary-root` KMS key to be
multi-region.

## Operating notes

```bash
# Read the master username (the password is in the same secret)
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw rds_secret_arn)" \
  --query SecretString --output text | jq -r .username

# Connectivity test from the Boundary node
pg_isready -h <address> -p 5432

# Manual snapshot before an engine upgrade or class change
aws rds create-db-snapshot --db-instance-identifier <project_name> \
  --db-snapshot-identifier <project_name>-pre-change-$(date +%Y%m%d%H%M)
```

- **Consumers read the password once, at boot.** After a rotation, a consumer
  must read the secret again before it can open new connections.
- **Major engine upgrades:** snapshot first, then change
  `database_engine_version`. Run `boundary database migrate` afterwards if the
  Boundary version changed too.

## Known limitations

- **`database_port` has no default**, so callers must pass a value or `null`.
- **Replicas are same-region only.** The source is referenced by identifier,
  which cannot address another region.
- **No parameter group.** TLS cannot be enforced on the server side. Boundary
  does connect with `sslmode=require`.
- **Storage always uses the AWS-managed key.** There is no input for a
  customer-managed one, and in RDS-managed mode the secret's key is not
  configurable either.
- **Fixed resource names.** The subnet group, security group and instance are
  named from `project_name` alone, so one instance per project per region.

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.11 |
| AWS provider | ~> 6.0 |
| Random provider | ~> 3.0 |
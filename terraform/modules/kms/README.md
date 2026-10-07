# KMS module

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![AWS KMS](https://img.shields.io/badge/AWS%20KMS-DD344C?style=for-the-badge)
![Vault](https://img.shields.io/badge/Vault-FFEC6E?style=for-the-badge&logo=vault&logoColor=black)
![Boundary](https://img.shields.io/badge/Boundary-EC585D?style=for-the-badge&logo=hashicorp&logoColor=white)

A deliberately small module: one symmetric customer-managed key and one alias
per call. The platform calls it once for each cryptographic purpose instead of
sharing a single key, so each key's blast radius, audit trail and IAM grants
stay independent.

## Keys in this platform

| Alias | Root module | Used by | Protects | If lost or disabled |
|---|---|---|---|---|
| `vault-unseal` | `kms_vault_unseal` | Vault's `awskms` seal, and the Vault init secret | Vault's root key, and so every secret in Vault. Also the recovery keys and initial root token. | Vault cannot unseal. Its data is unrecoverable. |
| `boundary-root` | `kms_boundary_root` | Boundary controller, and the Boundary init secret | The keys that encrypt credentials and session data in Postgres. | Boundary cannot read its database. |
| `boundary-worker-auth` | `kms_boundary_worker` | Boundary controller and worker | Worker registration and authentication. | Workers cannot join; sessions fail. |
| `boundary-recovery` | `kms_boundary_recovery` | Operators, as break-glass | Recovery access to the API when the auth method or admin login is broken. | No break-glass path. Normal operation is unaffected. |

## What it creates

- One symmetric KMS key, single-region by default, with annual rotation enabled
- One alias, `alias/<alias>`, pointing at the key

## Design decisions

- **One key per purpose.** Boundary requires separate root, worker-auth and
  recovery keys. The separation is also useful: the recovery key can be locked
  to a break-glass role, and replacing a compromised worker-auth key does not
  touch the encrypted database.
- **Rotation on by default.** KMS keeps every earlier version of the key
  material, so data encrypted before a rotation still decrypts. Neither Vault
  nor Boundary needs a restart or a re-wrap.
- **30-day deletion window.** Deleting `vault-unseal` or `boundary-root` makes
  that product's data permanently unreadable. The longest window gives the most
  time to notice and cancel.
- **Default key policy, access granted through IAM.** With no policy passed, AWS
  delegates control to IAM, and the `ec2` module grants each instance role only
  the actions it needs on only its own keys.
- **Multi-region is opt-in and permanent.** It can only be chosen when a key is
  created, so it is decided per key up front.

## Usage

```hcl
module "kms_vault_unseal" {
  source       = "./modules/kms"
  project_name = var.project_name
  alias        = "vault-unseal"
  multi_region = true
}

module "kms_boundary_root" {
  source       = "./modules/kms"
  project_name = var.project_name
  alias        = "boundary-root"
}

module "kms_boundary_worker" {
  source       = "./modules/kms"
  project_name = var.project_name
  alias        = "boundary-worker-auth"
}

module "kms_boundary_recovery" {
  source       = "./modules/kms"
  project_name = var.project_name
  alias        = "boundary-recovery"
}

module "ec2" {
  # ...
  kms_key_arns = {
    vault_unseal         = module.kms_vault_unseal.key_arn
    boundary_root        = module.kms_boundary_root.key_arn
    boundary_worker_auth = module.kms_boundary_worker.key_arn
    boundary_recovery    = module.kms_boundary_recovery.key_arn
  }
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Applied as the `Project` tag. |
| `alias` | `string` | required | Alias without the `alias/` prefix. Unique per account and region. |
| `description` | `string` | `null` | Key description, shown in the console and in CloudTrail. |
| `deletion_window_in_days` | `number` | `30` | Waiting period before a scheduled deletion takes effect (7 to 30). |
| `enable_key_rotation` | `bool` | `true` | Rotate the key material automatically once a year. |
| `multi_region` | `bool` | `false` | Create a multi-region primary key. Cannot be changed after creation. |
| `policy` | `string` | `null` | JSON key policy. `null` applies the AWS default policy. |
| `tags` | `map(string)` | `{}` | Merged with the `Project` and `Alias` tags. |

## Outputs

| Name | Description |
|---|---|
| `key_id` | Key ID. |
| `key_arn` | Key ARN. Pass this to the `ec2` module; IAM policies need the key ARN, not the alias ARN. |
| `alias_name` | `alias/<alias>`. |
| `alias_arn` | Alias ARN. |

## Who can use the keys

Granted by the `ec2` module, per instance role:

| Role | Keys | Actions | When |
|---|---|---|---|
| `vault` | `vault-unseal` | `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` | always |
| `vault` | `vault-unseal` | `kms:GenerateDataKey` | bootstrap automation on |
| `boundary` | `boundary-root`, `boundary-worker-auth`, `boundary-recovery` | `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` | always |
| `boundary` | `boundary-root` | `kms:GenerateDataKey` | bootstrap automation on |

The first three actions serve Vault's seal and Boundary's KMS configuration,
which call KMS directly. `GenerateDataKey` is only needed to write the init
secrets, because Secrets Manager encrypts them under these keys.

For production, a key policy that names the allowed roles explicitly is
stronger than the default, because an IAM administrator can no longer grant
themselves use of the key. Pass it through `policy`. A key policy that omits
both the account root and an admin role makes the key unmanageable, so include
an administration statement.

## Disaster recovery

KMS keys are regional, which shapes the pilot-light design:

- **Vault.** A Raft snapshot taken in the primary region is sealed by the
  primary `vault-unseal` key. Restoring it in the second region needs the same
  key material there, which is why that key is multi-region. The replica in the
  second region is a separate `aws_kms_replica_key` resource that this module
  does not create yet.
- **Boundary.** The recovery plan rebuilds Boundary's configuration with
  Terraform against a new database, so the second region can use its own keys
  and the Boundary keys stay single-region. Restoring the primary database
  instead would require `boundary-root` to be multi-region, and that cannot be
  changed on an existing key.

## Operating notes

```bash
# Inspect a key
aws kms describe-key --key-id alias/vault-unseal
aws kms get-key-rotation-status --key-id alias/vault-unseal

# Undo an accidental deletion within the window
aws kms cancel-key-deletion --key-id <key-id>
aws kms enable-key --key-id <key-id>
```

- **Before `terraform destroy`:** destroying a key schedules its deletion. Once
  the window passes, any Vault snapshot or Boundary database encrypted under it
  is unreadable.
- **Changing `multi_region`:** forces a new key. Only do it before the key
  protects any data.

## Known limitations

- **No replica key resource.** The multi-region primary exists, but the copy in
  the second region still has to be added.
- **`vault-unseal` has two jobs.** It seals Vault and also encrypts the secret
  holding the root token and recovery keys. A dedicated key for the init
  secrets would separate them.
- **The reserved `aws/` alias prefix is not rejected.** `alias = "aws/foo"`
  passes validation and fails at apply.
- **Default key policy.** Any principal an IAM administrator grants KMS access
  to can use the keys.

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.3 |
| AWS provider | ~> 6.0 |
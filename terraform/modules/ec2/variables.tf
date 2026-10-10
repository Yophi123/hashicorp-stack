## Identity

variable "project_name" {
  type        = string
  description = "Prefix for every resource name and the scope of the cloud auto-join tags. Use the same value in both regions so the sites can find each other."

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.project_name))
    error_message = "project_name must be 1-16 lowercase letters, digits or hyphens; IAM name prefixes are capped at 38 characters."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource created by this module."
  default     = {}
}

## Network
variable "vpc_id" {
  type        = string
  description = "VPC the instances launch into."
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of the VPC. Source for intra-cluster security group rules (gossip, raft, RPC) and for traffic from the ALB."

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Subnets for every node group that does not set public_ip."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnets."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Subnets for node groups that set public_ip (the Boundary worker). May be empty when no group does."
  default     = []
}

## Images

variable "ami_owners" {
  type        = list(string)
  description = "Account IDs that own the Packer AMIs. \"self\" is the account running Terraform."
  default     = ["self"]
}

variable "ami_role_tags" {
  type = object({
    nomad_consul_server = optional(string, "nomad-consul-control-plane")
    nomad_worker        = optional(string, "nomad-consul-client-plane")
    boundary            = optional(string, "boundary-plane")
    vault               = optional(string, "vault-control-plane")
  })
  description = "Value of the Role tag Packer stamps on each AMI. The newest available AMI with that tag is used."
  default     = {}
}

## Node groups

variable "node_groups" {
  type = map(object({
    instance_type    = optional(string, "t3.small")
    min_size         = optional(number, 1)
    max_size         = optional(number, 3)
    desired_capacity = optional(number, 1)

    # Launch in public_subnet_ids with a public IP. Only the Boundary worker needs this.
    public_ip = optional(bool, false)

    root_volume_size = optional(number, 10)
    # Second gp3 volume for raft data or Nomad allocations. Null means root disk only.
    data_volume_size = optional(number)

    spot_enabled = optional(bool, false)

    health_check_type         = optional(string, "EC2")
    health_check_grace_period = optional(number, 300)

    extra_user_data = optional(string, "")
    extra_tags      = optional(map(string), {})
  }))

  description = <<-EOT
    One ASG per key. Keys are fixed: nomad_consul_server (Consul and Nomad
    servers together), vault, boundary (controller and worker together) and
    nomad_worker. Leave a key out to skip that group, e.g. boundary in the
    pilot-light region.

    Terraform ignores later changes to desired_capacity so a failover script
    can scale groups with the AWS CLI. To resize a raft group through
    Terraform, change min_size and desired_capacity together.
  EOT

  default = {
    nomad_consul_server = {}
    vault               = { data_volume_size = 10 }
    boundary            = { public_ip = true }
    nomad_worker        = { max_size = 3 }
  }

  validation {
    condition = alltrue([
      for k in keys(var.node_groups) :
      contains(["nomad_consul_server", "nomad_worker", "boundary", "vault"], k)
    ])
    error_message = "node_groups keys must be nomad_consul_server, nomad_worker, boundary or vault."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups :
      g.min_size <= g.desired_capacity && g.desired_capacity <= g.max_size
    ])
    error_message = "Each group needs min_size <= desired_capacity <= max_size."
  }

  validation {
    condition = (
      contains([1, 3, 5], try(var.node_groups["nomad_consul_server"].desired_capacity, 1)) &&
      contains([0, 1, 3, 5], try(var.node_groups["vault"].desired_capacity, 1))
    )
    error_message = "Raft groups run 1, 3 or 5 nodes (vault may be 0 in a pilot-light region). Even counts add cost without fault tolerance."
  }

  validation {
    condition = alltrue([
      for k in ["nomad_consul_server", "vault"] :
      try(var.node_groups[k].min_size == var.node_groups[k].desired_capacity, true)
    ])
    error_message = "For nomad_consul_server and vault, set min_size equal to desired_capacity so a resize actually rolls out."
  }

  validation {
    condition = alltrue([
      for k in ["nomad_consul_server", "vault"] :
      try(var.node_groups[k].spot_enabled, false) == false
    ])
    error_message = "Do not run raft members on spot; an interruption is an unplanned quorum loss."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : contains(["EC2", "ELB"], g.health_check_type)
    ])
    error_message = "health_check_type must be EC2 or ELB."
  }
}

variable "instance_refresh_enabled" {
  type        = bool
  description = "Roll instances when a launch template changes. With a single raft node this replaces the only copy of the data, so keep it off until snapshot restore on boot exists."
  default     = false
}

## Cluster identity

variable "consul_datacenter" {
  type        = string
  description = "Consul datacenter name for this site. Must differ between the two regions."

  validation {
    condition     = can(regex("^[a-z0-9_-]+$", var.consul_datacenter))
    error_message = "consul_datacenter may contain only lowercase letters, digits, underscores and hyphens."
  }
}

variable "nomad_region" {
  type        = string
  description = "Nomad region name for this site. Must differ between the two regions, and cannot be changed after the servers bootstrap."

  validation {
    condition     = can(regex("^[a-z0-9_-]+$", var.nomad_region))
    error_message = "nomad_region may contain only lowercase letters, digits, underscores and hyphens."
  }
}

variable "retry_join_tag_key" {
  type        = string
  description = "Tag key for cloud auto-join. Each instance is tagged <key> = <project_name>-<node_group>."
  default     = "HashiStackJoin"
}

variable "federation" {
  type = object({
    consul_primary_datacenter  = optional(string)
    nomad_authoritative_region = optional(string)
    peer_vpc_cidrs             = optional(list(string), [])
    peer_aws_regions           = optional(list(string), [])
  })
  description = <<-EOT
    Cross-region wiring; the default leaves this site standalone.
    peer_vpc_cidrs opens the server RPC and WAN gossip ports to the peered
    VPCs. peer_aws_regions lists the AWS regions whose servers this site
    WAN-joins through cloud auto-join. The primary datacenter and
    authoritative region take the same value at both sites.
  EOT
  default     = {}

  validation {
    condition     = alltrue([for c in var.federation.peer_vpc_cidrs : can(cidrnetmask(c))])
    error_message = "Each federation.peer_vpc_cidrs entry must be a valid IPv4 CIDR block."
  }
}

## KMS

variable "kms_key_arns" {
  type = object({
    vault_unseal         = optional(string)
    boundary_root        = optional(string)
    boundary_worker_auth = optional(string)
    boundary_recovery    = optional(string)
    ebs                  = optional(string)
  })
  description = "KMS keys from the kms module. vault_unseal is required when the vault group exists, the three boundary keys when the boundary group exists. ebs is optional; null uses the AWS-managed key."
  default     = {}
}

## Boundary database
variable "boundary_db" {
  type = object({
    host       = string
    port       = number
    dbname     = string
    secret_arn = string
  })
  description = "Boundary's Postgres coordinates from the rds module. Required when the boundary group exists. The password is fetched from secret_arn at boot."
  default     = null
}

variable "boundary_db_kms_key_id" {
  type        = string
  description = "KMS key that encrypts the database master secret, so the Boundary role can decrypt it. Null when the secret uses the AWS-managed key."
  default     = null
}

variable "boundary_db_security_group_id" {
  type        = string
  description = "RDS security group ID, used to add the 5432 ingress rule from the Boundary security group."
  default     = null
}

variable "create_rds_ingress_rule" {
  type        = bool
  description = "Add the 5432 ingress rule to the RDS security group. A separate flag because count cannot depend on an ID that is unknown until apply."
  default     = true
}

## Load balancing and client access

variable "target_group_arns" {
  type        = map(list(string))
  description = "ALB target group ARNs to attach to each ASG, keyed by node group. Pass the alb module's output."
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.target_group_arns) :
      contains(["nomad_consul_server", "nomad_worker", "boundary", "vault"], k)
    ])
    error_message = "target_group_arns keys must be node group names."
  }
}

variable "allowed_client_cidrs" {
  type        = list(string)
  description = "Source CIDRs allowed to reach the Boundary worker proxy port directly, i.e. your laptop. Deliberately no default."

  validation {
    condition     = alltrue([for c in var.allowed_client_cidrs : can(cidrnetmask(c))])
    error_message = "Each allowed_client_cidrs entry must be a valid IPv4 CIDR block."
  }
}

## Access

variable "enable_ssm" {
  type        = bool
  description = "Attach AmazonSSMManagedInstanceCore to every instance profile. The break-glass path until Boundary works."
  default     = true
}

## Bootstrap automation
variable "enable_bootstrap_automation" {
  type        = bool
  description = "Run vault operator init and boundary database init automatically on first boot, with a DynamoDB lock electing the one node that does it. Off means you init both by hand over SSM."
  default     = true
}

## Vault snapshots
variable "vault_snapshots" {
  type = object({
    bucket_name      = string
    bucket_arn       = string
    interval_minutes = optional(number, 10)

    copy_to = optional(list(object({
      bucket_name = string
      bucket_arn  = string
      region      = string
    })), [])
  })
  description = <<-EOT
    S3 bucket for Vault Raft snapshots. When set, the active Vault node saves a
    snapshot on a timer, and a new node with no data restores the latest one
    instead of initializing. copy_to lists buckets in other regions that get a
    second copy of every snapshot. Requires enable_bootstrap_automation.
  EOT
  default     = null
}

## Secrets
variable "init_secret_arns" {
  type = object({
    vault    = optional(string)
    boundary = optional(string)
  })
  description = "Secrets Manager secrets that receive the first-boot init output. Each is required when enable_bootstrap_automation is on and its node group exists."
  default     = {}
}

## Consul and Nomad snapshots
variable "server_snapshots" {
  type = object({
    bucket_name      = string
    bucket_arn       = string
    interval_minutes = optional(number, 10)
  })
  description = <<-EOT
    S3 bucket for Consul and Nomad Raft snapshots. When set, the leader of each
    saves a snapshot on a timer. A single-server cluster also restores the
    latest snapshots on first boot, so replacing the server keeps its state.
    Use a bucket in the same region; snapshots are never shared across regions.
  EOT
  default     = null
}
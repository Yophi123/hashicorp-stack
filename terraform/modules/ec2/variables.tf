variable "project_name" {
  type        = string
  description = "Project name for all associated resources"
}

variable "region" {
  type        = string
  description = "AWS region for the whole stack."
}

# VPC Network 
variable "vpc_id" {
  type        = string
  description = "VPC to launch EC2 instances into."
}

variable "vpc_cidr" {
  type        = string
  description = <<-EOT
    IPv4 CIDR of the VPC. Used as the default source for intra-cluster
    security group rules (gossip, raft, RPC) instead of hardcoding SG pairs
    where a CIDR is clearer.
    EOT
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Web-tier subnet IDs. Only the internet-facing NLB lives here; no instance in this module gets a public IP."

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Provide at least two public subnets so the external NLB is multi-AZ."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "App-tier subnet IDs. All four ASGs and the internal NLB live here."

  validation {
    condition     = length(var.private_subnet_ids) >= 3
    error_message = "Provide at least three private subnets; raft quorum wants three AZs."
  }
}

variable "private_zone_id" {
  type        = string
  description = "Route53 private hosted zone ID. Pass module.vpc.zone_id."
}

variable "private_zone_name" {
  type        = string
  description = <<-EOT
    Private zone name without the trailing dot, e.g. hashicorp-stack.internal.
    Service records are created as <service>.<private_zone_name> as aliases onto the internal NLB.
  EOT
}

variable "service_hostnames" {
  type = object({
    vault    = optional(string, "vault")
    consul   = optional(string, "consul")
    nomad    = optional(string, "nomad")
    boundary = optional(string, "boundary")
  })
  description = <<-EOT
    Record names relative to the private zone, one per service. These end up
    in TLS SANs and Boundary target addresses, so changing them later is a
    certificate regeneration, not a rename.
  EOT
  default     = {}
}

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
  description = <<-EOT
    Value of the `Role` tag Packer stamps on each AMI. The lookup matches on
    this tag rather than on the AMI name, so renaming your image naming scheme
    does not break the data source.
  EOT
  default     = {}
}

variable "node_groups" {
  type = map(object({
    instance_type    = optional(string, "t3.micro")
    min_size         = optional(number, 3)
    max_size         = optional(number, 5)
    desired_capacity = optional(number, 3)

    root_volume_size = optional(number, 10)
    root_volume_type = optional(string, "gp3")

    # Second volume for raft / Nomad allocs. Null means root disk only.
    data_volume_size = optional(number)
    data_volume_type = optional(string, "gp3")
    data_volume_iops = optional(number)

    # Spot is fine for nomad workers, not for anything holding raft state.
    spot_enabled         = optional(bool, false)
    spot_max_price       = optional(string)
    on_demand_base_count = optional(number, 0)

    health_check_type         = optional(string, "EC2")
    health_check_grace_period = optional(number, 300)
    detailed_monitoring       = optional(bool, false)

    extra_user_data = optional(string, "")
    extra_tags      = optional(map(string), {})
  }))

  description = <<-EOT
    Sizing and disk knobs per ASG. Keys are fixed and must be exactly:
    nomad_consul_server (Nomad servers + Consul servers), nomad_worker,
    boundary (controllers and workers on the same instance), vault.

    Ports, listeners, target groups and health checks are not configurable
    here - they are facts about the products and live in locals.tf.
  EOT

  default = {
    nomad_consul_server = {}
    nomad_worker        = { min_size = 2, max_size = 4, desired_capacity = 2 }
    boundary            = { min_size = 2, max_size = 4, desired_capacity = 2 }
    vault               = { data_volume_size = 50 }
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
      for k in ["nomad_consul_server", "vault"] :
      try(var.node_groups[k].min_size, 3) >= 3
    ])
    error_message = "nomad_consul_server and vault need min_size >= 3 for raft quorum."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups :
      g.desired_capacity >= g.min_size && g.desired_capacity <= g.max_size
    ])
    error_message = "desired_capacity must sit between min_size and max_size."
  }

  validation {
    condition     = try(var.node_groups["vault"].data_volume_size, null) != null
    error_message = "vault needs a data_volume_size; raft state must not live on an ephemeral root disk."
  }

  validation {
    condition     = try(var.node_groups["vault"].spot_enabled, false) == false && try(var.node_groups["nomad_consul_server"].spot_enabled, false) == false
    error_message = "Do not run raft members on spot; an interruption is an unplanned quorum loss."
  }
}

variable "instance_refresh_enabled" {
  type        = bool
  description = <<-EOT
    Roll instances when the launch template changes. Leave this off for vault
    and the control plane until you are confident in the auto-unseal and
    autopilot path; a rolling replace of a raft cluster is a real operation.
  EOT
  default     = false
}

## Cluster bootstrap
variable "consul_datacenter" {
  type        = string
  description = "Consul datacenter name, also used for Nomad's region/datacenter naming."
  default     = "dc1"
}

variable "retry_join_tag_key" {
  type        = string
  description = <<-EOT
    Tag key used for cloud auto-join. Instances are tagged with this key and
    the cluster name, and agents are configured with
    provider=aws tag_key=<this> tag_value=<cluster>.
  EOT
  default     = "ConsulAutoJoin"
}

variable "bootstrap_expect" {
  type        = number
  description = "Server count Consul/Nomad wait for before bootstrapping. Should match nomad_consul_server desired_capacity."
  default     = 3
}

## KMS
variable "kms_key_arns" {
  type = object({
    vault_unseal         = string
    boundary_root        = string
    boundary_worker_auth = string
    boundary_recovery    = string
    ebs                  = optional(string)
  })
  description = <<-EOT
    KMS keys the instances need. Vault uses awskms auto-unseal; Boundary needs
    three separate purpose keys. `ebs` is optional and only used if you want
    volumes encrypted with a CMK rather than the AWS-managed key.
  EOT
}


## Database - Boundary only
variable "boundary_db" {
  type = object({
    host       = string
    port       = number
    dbname     = string
    secret_arn = string
  })
  description = <<-EOT
    Boundary's Postgres coordinates. Pass module.rds.connection. The password
    is not here by design; instances fetch it from secret_arn at boot.
  EOT
}

variable "boundary_db_kms_key_id" {
  type        = string
  description = "KMS key for the managed master secret, so the Boundary role can decrypt it."
  default     = null
}

variable "boundary_db_security_group_id" {
  type        = string
  description = "RDS security group ID, so this module can add the 5432 ingress rule from the Boundary SG."
  default     = null
}

variable "create_rds_ingress_rule" {
  type        = bool
  description = <<-EOT
    Add the 5432 ingress rule to the RDS security group. Separate from
    boundary_db_security_group_id because count cannot depend on an ID that
    is unknown until apply.
  EOT
  default     = true
}

## Load Balancers
variable "allowed_client_cidrs" {
  type        = list(string)
  description = <<-EOT
    Source CIDRs allowed to reach the internet-facing NLB, i.e. your laptop.
    Defaulting this to 0.0.0.0/0 would publish the Boundary control plane to
    the internet, so there is deliberately no default.
  EOT

  validation {
    condition     = alltrue([for c in var.allowed_client_cidrs : can(cidrnetmask(c))])
    error_message = "Each entry must be a valid CIDR block."
  }
}

variable "enable_cross_zone_load_balancing" {
  type        = bool
  description = "Cross-zone balancing on both NLBs. Costs inter-AZ data transfer, worth it for an odd node count."
  default     = true
}

variable "enable_deletion_protection" {
  type        = bool
  description = "Deletion protection on both NLBs."
  default     = false
}

variable "nlb_access_logs" {
  type = object({
    enabled = optional(bool, false)
    bucket  = optional(string)
    prefix  = optional(string)
  })
  description = "NLB access logs. If enabled is true, bucket is required."
  default     = {}

  validation {
    condition     = !coalesce(var.nlb_access_logs.enabled, false) || var.nlb_access_logs.bucket != null
    error_message = "Set nlb_access_logs.bucket when access logs are enabled."
  }
}

variable "target_group_deregistration_delay" {
  type        = number
  description = "Seconds to drain before deregistering. Keep this above the Boundary session grace period."
  default     = 60
}

# Access
variable "enable_ssm" {
  type        = bool
  description = <<-EOT
    Attach AmazonSSMManagedInstanceCore to every instance profile. Worth
    keeping on as the break-glass path while Boundary itself is being built,
    since the instances have no public IPs and no inbound SSH.
  EOT
  default     = true
}

variable "key_name" {
  type        = string
  description = "EC2 key pair name. Null means no key pair; use SSM or Boundary instead."
  default     = null
}

variable "additional_security_group_ids" {
  type        = map(list(string))
  description = "Extra security group IDs to attach, keyed by node group name."
  default     = {}
}

variable "enable_imdsv2_only" {
  type        = bool
  description = "Require IMDSv2 (http_tokens = required) on all launch templates."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto all resources created by this module."
  default     = {}
}

## Bootstrap Automation
variable "enable_bootstrap_automation" {
  type        = bool
  description = <<-EOT
    Run `vault operator init` and `boundary database init` automatically on
    first boot, electing one node via a DynamoDB lock. Turn this off if you
    would rather hold the recovery keys yourself and never let them touch
    Secrets Manager.
  EOT
  default     = true
} 
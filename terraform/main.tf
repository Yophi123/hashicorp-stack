## Networking
# VPC
module "networking" {
  source            = "./modules/vpc"
  project_name      = "hashicorp-stack"
  private_zone_name = "hashicorp-stack.internal"
}

# Pilot-light VPC
module "networking_pilot_light" {
  source = "./modules/vpc"

  providers = {
    aws = aws.pilot_light
  }

  project_name      = "hashicorp-stack"
  vpc_cidr          = "10.17.0.0/16"
  private_zone_name = "hashicorp-stack-pilot-light.internal"
}

module "vpc_peering" {
  source       = "./modules/vpc-peering"
  project_name = "hashicorp-stack"
  providers = {
    aws      = aws
    aws.peer = aws.pilot_light
  }

  vpc-id   = module.networking.vpc-id
  vpc_cidr = module.networking.vpc-cidr_block

  route_table_ids = {
    public  = module.networking.public_route_table_id
    private = module.networking.private_route_table_id
  }

  peer_region   = var.pilot_light_region
  peer_vpc-id   = module.networking_pilot_light.vpc-id
  peer_vpc_cidr = module.networking_pilot_light.vpc-cidr_block
  peer_route_table_ids = {
    public  = module.networking_pilot_light.public_route_table_id
    private = module.networking_pilot_light.private_route_table_id
  }
}

# RDS
module "boundary_rds" {
  source                      = "./modules/rds"
  project_name                = "hashicorp-stack"
  database_engine             = "postgres"
  database_engine_version     = "18.3"
  database_port               = 5432
  db_instance_class           = "db.t3.micro"
  vpc_id                      = module.networking.vpc-id
  username                    = "hashicorp_user"
  manage_master_user_password = false
  subnet_ids                  = module.networking.db_subnet_ids
  # Evaluation posture: allows a clean `terraform destroy`. Flip both for production.
  skip_final_snapshot = true
  deletion_protection = false
}

## KMS Keys
module "kms_vault_unseal" {
  project_name = "hashicorp-stack"
  source       = "./modules/kms"
  alias        = "vault-unseal"
  multi_region = true
}

## KMS Key wraps everything Boundary stores in Postgres — target credentials, host catalog secrets, per-scope key hierarchies
module "kms_boundary_root" {
  project_name = "hashicorp-stack"
  source       = "./modules/kms"
  alias        = "boundary-root"
}

## KMS key for how a worker proves its identity to a controller.
module "kms_boundary_worker" {
  source       = "./modules/kms"
  alias        = "boundary-worker-auth"
  project_name = "hashicorp-stack"
}

## KMS key for a break-glass path into the API when you've lost admin credentials or the auth method is broken.
module "kms_boundary_recovery" {
  source       = "./modules/kms"
  alias        = "boundary-recovery"
  project_name = "hashicorp-stack"
}

module "kms_vault_unseal_pilot_light" {
  source = "./modules/kms-replica"

  providers = {
    aws = aws.pilot_light
  }

  project_name    = "hashicorp-stack"
  alias           = "vault-unseal"
  primary_key_arn = module.kms_vault_unseal.key_arn
}


# Secrets
module "vault_init_secret" {
  source = "./modules/secrets"

  project_name = "hashicorp-stack"
  name_prefix  = "hashicorp-stack/vault/init-"
  description  = "Vault recovery keys and initial root token"
  kms_key_id   = module.kms_vault_unseal.key_arn

  # Readable in the pilot-light region when the primary is down.
  replicas = [{
    region     = var.pilot_light_region
    kms_key_id = module.kms_vault_unseal_pilot_light.key_arn
  }]
}

module "boundary_init_secret" {
  source = "./modules/secrets"

  project_name = "hashicorp-stack"
  name_prefix  = "hashicorp-stack/boundary/init-"
  description  = "Boundary initial admin credentials and auth method ID"
  kms_key_id   = module.kms_boundary_root.key_arn
}

# Relocate the existing secrets instead of recreating them.
moved {
  from = module.ec2.aws_secretsmanager_secret.vault_init[0]
  to   = module.vault_init_secret.aws_secretsmanager_secret.this
}

moved {
  from = module.ec2.aws_secretsmanager_secret.boundary_init[0]
  to   = module.boundary_init_secret.aws_secretsmanager_secret.this
}

# ALB
module "alb" {
  source = "./modules/alb"

  project_name      = "hashicorp-stack"
  vpc_id            = module.networking.vpc-id
  vpc_cidr          = module.networking.vpc-cidr_block
  public_subnet_ids = module.networking.web_subnet_ids

  public_zone_name     = var.hashicorp_stack_domain
  allowed_client_cidrs = var.allowed_client_cidrs

  # Only Boundary is public. Everything else is reached through it.
  services = {
    boundary = {
      hostname    = "boundary"
      node_group  = "boundary"
      port        = module.ec2.ports.boundary.api
      health_port = module.ec2.ports.boundary.ops
      health_path = "/health"
    }
  }
}

module "snapshots" {
  source = "./modules/s3"

  project_name      = "hashicorp-stack"
  name              = "snapshots"
  expiring_prefixes = { "vault/history/" = 7 }

  # Evaluation posture: allows a clean terraform destroy.
  force_destroy = true
}

module "snapshots_pilot_light" {
  source = "./modules/s3"

  providers = {
    aws = aws.pilot_light
  }

  project_name      = "hashicorp-stack"
  name              = "snapshots"
  expiring_prefixes = { "vault/history/" = 7 }
  force_destroy     = true
}

module "ec2" {
  source = "./modules/ec2"

  project_name = "hashicorp-stack"
  vpc_id       = module.networking.vpc-id
  vpc_cidr     = module.networking.vpc-cidr_block

  private_subnet_ids = module.networking.app_subnet_ids
  public_subnet_ids  = module.networking.web_subnet_ids

  # Using the AWS region for both names keeps the two sites distinct for free.
  consul_datacenter = var.region
  nomad_region      = var.region

  # Can change the instance type based on requirements 
  node_groups = {
    nomad_consul_server = { instance_type = "t3.small", data_volume_size = 10}
    vault               = { instance_type = "t3.small", data_volume_size = 10 }
    boundary            = { instance_type = "t3.small", public_ip = true }
    nomad_worker        = { instance_type = "t3.medium", max_size = 3 }
  }

  kms_key_arns = {
    vault_unseal         = module.kms_vault_unseal.key_arn
    boundary_root        = module.kms_boundary_root.key_arn
    boundary_worker_auth = module.kms_boundary_worker.key_arn
    boundary_recovery    = module.kms_boundary_recovery.key_arn
  }

  boundary_db                   = module.boundary_rds.connection
  boundary_db_security_group_id = module.boundary_rds.security_group_id

  target_group_arns    = module.alb.target_group_arns
  allowed_client_cidrs = var.allowed_client_cidrs

  vault_snapshots = {
    bucket_name = module.snapshots.bucket_name
    bucket_arn  = module.snapshots.bucket_arn
    copy_to = [{
      bucket_name = module.snapshots_pilot_light.bucket_name
      bucket_arn  = module.snapshots_pilot_light.bucket_arn
      region      = var.pilot_light_region
    }]
  }

  init_secret_arns = {
    vault    = module.vault_init_secret.arn
    boundary = module.boundary_init_secret.arn
  }

  # Federation
   federation = {
    consul_primary_datacenter  = var.region
    nomad_authoritative_region = var.region
    peer_vpc_cidrs             = [module.networking_pilot_light.vpc-cidr_block]
    peer_aws_regions           = [var.pilot_light_region]
  }
}

module "ec2_pilot_light" {
  source = "./modules/ec2"

  providers = {
    aws = aws.pilot_light
  }

  project_name = "hashicorp-stack"
  vpc_id       = module.networking_pilot_light.vpc-id
  vpc_cidr     = module.networking_pilot_light.vpc-cidr_block

  private_subnet_ids = module.networking_pilot_light.app_subnet_ids

  consul_datacenter = var.pilot_light_region
  nomad_region      = var.pilot_light_region

  # One server always on. Vault and the workers start at zero and are scaled
  # up at failover. No Boundary here yet.
  node_groups = {
    nomad_consul_server = {}
    vault               = { min_size = 0, desired_capacity = 0, data_volume_size = 10 }
    nomad_worker        = { min_size = 0, desired_capacity = 0, max_size = 3 }
  }

  kms_key_arns = {
    vault_unseal = module.kms_vault_unseal_pilot_light.key_arn
  }

  init_secret_arns = {
    vault = module.vault_init_secret.replica_arns[var.pilot_light_region]
  }

  vault_snapshots = {
    bucket_name = module.snapshots_pilot_light.bucket_name
    bucket_arn  = module.snapshots_pilot_light.bucket_arn
  }

  # Federation
  federation = {
    consul_primary_datacenter  = var.region
    nomad_authoritative_region = var.region
    peer_vpc_cidrs             = [module.networking.vpc-cidr_block]
    peer_aws_regions           = [var.region]
  }

  allowed_client_cidrs = var.allowed_client_cidrs

  depends_on = [ module.ec2 ]
}
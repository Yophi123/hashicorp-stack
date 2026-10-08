# VPC
module "networking" {
  source            = "./modules/vpc"
  project_name      = "hashicorp-stack"
  private_zone_name = "hashicorp-stack.internal"
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
  }
}

# VPC
module "networking" {
  source            = "./modules/vpc"
  project_name      = "hashicorp-stack"
  private_zone_name = "hashicorp-stack.internal"
}

# RDS
module "rds" {
  source                  = "./modules/rds"
  project_name            = "hashicorp-stack"
  database_engine         = "postgres"
  database_engine_version = "18.3"
  database_port           = 5432
  db_instance_class       = "db.t3.micro"
  vpc_id                  = module.networking.vpc-id
  username                = "hashicorp_user"
  subnet_ids              = module.networking.db_subnet_ids
  # Evaluation posture: allows a clean `terraform destroy`. Flip both for production.
  skip_final_snapshot = true
  deletion_protection = false
}

# KMS Keys
module "kms_vault_unseal" {
  project_name = "hashicorp-stack"
  source       = "./modules/kms"
  alias        = "vault-unseal"
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

module "ec2" {
  source       = "./modules/ec2"
  project_name = "hashicorp-stack"
  region       = var.region

  vpc_id             = module.networking.vpc-id
  vpc_cidr           = module.networking.vpc-cidr_block
  public_subnet_ids  = module.networking.web_subnet_ids
  private_subnet_ids = module.networking.app_subnet_ids
  private_zone_id    = module.networking.zone_id
  private_zone_name  = module.networking.zone_name
  kms_key_arns = {
    vault_unseal         = module.kms_vault_unseal.key_arn
    boundary_root        = module.kms_boundary_root.key_arn
    boundary_worker_auth = module.kms_boundary_worker.key_arn
    boundary_recovery    = module.kms_boundary_recovery.key_arn
  }

  boundary_db = {
    host       = module.rds.address
    port       = module.rds.port
    dbname     = module.rds.dbname
    secret_arn = module.rds.master_user_secret_arn
  }

  boundary_db_security_group_id = module.rds.security_group_id
  allowed_client_cidrs          = var.allowed_client_cidrs
  node_groups = {
    nomad_consul_server = {}
    nomad_worker        = { min_size = 2, max_size = 4, desired_capacity = 2 }
    boundary            = { min_size = 2, max_size = 4, desired_capacity = 2 }
    vault               = { data_volume_size = 10 }
  }
}

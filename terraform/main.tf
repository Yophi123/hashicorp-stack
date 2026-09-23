module "networking" {
  source            = "./modules/vpc"
  project_name      = "hashicorp-stack"
  private_zone_name = "hashicorp-stack"
}

# module "rds" {
#   source                  = "./modules/rds"
#   project_name            = "hashicorp-stack"
#   database_engine         = "postgres"
#   database_engine_version = "18.3"
#   database_port           = "5432"
#   db_instance_class       = "db.t3.micro"
#   vpc_id                  = module.networking.vpc-id
#   username                = "hashicorp_user"
#   subnet_ids              = module.networking.db_subnet_ids
#   skip_final_snapshot =     true
# }
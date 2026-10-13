terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.2"
    }
  }
}

# Read at plan and apply time only; the root token never reaches the state file.
ephemeral "aws_secretsmanager_secret_version" "init" {
  for_each  = local.init_secrets
  secret_id = lookup(var.init_secret_arns, each.key, try(one(data.aws_secretsmanager_secrets.init[each.key].arns), null))

  lifecycle {
    precondition {
      condition     = lookup(var.init_secret_arns, each.key, try(one(data.aws_secretsmanager_secrets.init[each.key].arns), null)) != null
      error_message = "No ${each.key} init secret found under \"${var.project_name}/${each.key}/init-\" in ${data.aws_region.current.region}. Pass its ARN in init_secret_arns."
    }
  }
}

locals {
  vault_init    = jsondecode(ephemeral.aws_secretsmanager_secret_version.init["vault"].secret_string)
  boundary_init = jsondecode(ephemeral.aws_secretsmanager_secret_version.init["boundary"].secret_string)
}

provider "aws" {
  region  = var.region
  profile = "terraform"
}

provider "vault" {
  address = var.vault_addr
  token   = local.vault_init.root_token
}

provider "boundary" {
  addr                   = var.boundary_addr
  auth_method_id         = local.boundary_init.auth_method.auth_method_id
  auth_method_login_name = local.boundary_init.auth_method.login_name
  auth_method_password   = local.boundary_init.auth_method.password
}
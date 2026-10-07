terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # backend "s3" {
  #   bucket       = "hashicorp-stack-04321"
  #   region       = "ap-southeast-1"
  #   encrypt      = true
  #   use_lockfile = true
  #   key          = "hashicorp-stack/terraform.tfstate"
  # }
}

provider "aws" {
  region  = var.region
  profile = "terraform"
}
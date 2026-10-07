
data "aws_route53_zone" "public" {
  name         = var.hashicorp_stack_domain
  private_zone = false
}

data "aws_ami_ids" "hashicorp_stack_amis" {
  owners      = ["self"]
  
  filter {
    name   = "tag:Project"
    values = ["hashicorp-stack"]
  }

  filter {
    name   = "tag:BuiltBy"
    values = ["packer"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

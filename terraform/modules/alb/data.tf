data "aws_region" "current" {}

data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

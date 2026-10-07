data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # excludes Local/Wavelength Zones
  }
}

data "aws_region" "current" {}

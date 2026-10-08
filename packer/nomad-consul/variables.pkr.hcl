variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "ami_regions" {
  type    = list(string)
  default = ["eu-west-1"]
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}


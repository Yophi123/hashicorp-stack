packer {
  required_plugins {
    amazon = {
      version = "~> 1.8"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

locals {
  timestamp = formatdate("YYYY-MM-DD", timestamp())
}

source "amazon-ebs" "boundary" {
  region        = var.region
  # ami_regions   = var.ami_regions
  instance_type = var.instance_type
  profile       = "packer"
  ami_name      = "boundary-server-${local.timestamp}"
  ssh_username  = "ubuntu"

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd*/ubuntu-resolute-26.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Ubuntu
    most_recent = true
  }

  tags = {
    Name    = "boundary-server"
    Role    = "boundary-plane"
    BuiltBy = "packer"
    Project = "hashicorp-stack"
  }
}

build {
  sources = ["source.amazon-ebs.boundary"]

  provisioner "file" {
    source      = "./scripts"
    destination = "/tmp/scripts"
  }

  provisioner "shell" {
    inline = [
      "echo '==> Making scripts executable...'",
      "chmod +x /tmp/scripts/*.sh",

      "echo '==> Executing setup script...'",
      "sudo /tmp/scripts/install.sh",

      "echo '==> Cleaning up temporary upload directory...'",
      "rm -rf /tmp/scripts"
    ]
  }
}

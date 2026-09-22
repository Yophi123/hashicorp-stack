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

source "amazon-ebs" "boundary-vault" {
  region        = var.region
  instance_type = var.instance_type
  profile       = "packer"
  ami_name      = "boundary-vault-server-${local.timestamp}"
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
    Name    = "boundary-vault-server"
    Role    = "boundary-vault-control-plane"
    BuiltBy = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.boundary-vault"]

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
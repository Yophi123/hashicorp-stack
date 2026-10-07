#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> [1/5] Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y \
    curl \
    wget \
    gpg \
    coreutils \
    jq \
    postgresql-client \
    lsb-release \
    apt-transport-https \
    ca-certificates \
    jq \
    unzip \
    nvme-cli

echo "==> Installing AWS CLI"    
# AWS CLI v2, used by user data to read secrets and attach volumes.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/aws /tmp/awscliv2.zip

echo "==> [2/5] Installing Hashicorp Repo..."
install -m 0755 -d /etc/apt/keyrings
wget -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list

echo "==> [3/5] Installing Boundary and Consul..."
apt-get update -y
apt-get install -y boundary consul postgresql-client

# Send *.consul lookups to the local Consul agent; everything else is untouched.
sudo install -d -m 0755 /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/consul.conf >/dev/null <<'EOF'
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF
sudo systemctl restart systemd-resolved

echo "==> [4/5] Leaving services disabled until user data writes their config..."
systemctl disable --now boundary consul
rm -f /etc/boundary.d/boundary.hcl /etc/consul.d/consul.hcl

echo "==> [5/5] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"
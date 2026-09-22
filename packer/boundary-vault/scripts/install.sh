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
    lsb-release \
    apt-transport-https \
    ca-certificates

echo "==> [2/5] Installing Hashicorp Repo..."
install -m 0755 -d /etc/apt/keyrings
wget -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list

echo "==> [3/5] Installing Boundary and Vault..."
apt-get update -y
apt-get install -y boundary vault 

echo "==> [4/5] Enabling Systemd services..."
systemctl enable boundary
systemctl enable vault

echo "==> [5/5] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"
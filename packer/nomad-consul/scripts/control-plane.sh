#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CNI_VERSION="v1.6.2"


echo "==> [1/8] Updating packages and installing dependencies..."
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

echo "==> [2/8] Installing Hashicorp Repo..."
install -m 0755 -d /etc/apt/keyrings
wget -O - https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list

echo "==> [3/7] Installing Consul and Nomad..."
apt-get update -y
apt-get install -y consul nomad 

echo "==> [5/8] Installing CNI Plugins for Nomad..."
mkdir -p /opt/cni/bin
curl -L -o /tmp/cni-plugins.tgz "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-$(dpkg --print-architecture)-${CNI_VERSION}.tgz"
tar -C /opt/cni/bin -xzf /tmp/cni-plugins.tgz
rm -f /tmp/cni-plugins.tgz

# Ensure system iptables are configured for CNI bridging
echo "net.bridge.bridge-nf-call-arptables = 1" | tee -a /etc/sysctl.d/bridge.conf > /dev/null
echo "net.bridge.bridge-nf-call-iptables = 1"  | tee -a /etc/sysctl.d/bridge.conf > /dev/null
echo "net.bridge.bridge-nf-call-ip6tables = 1" | tee -a /etc/sysctl.d/bridge.conf > /dev/null

echo "==> [6/8] Creating directory structure and system users..."
# Consul setup
id -u consul &>/dev/null || useradd --system --home /etc/consul.d --shell /bin/false consul
mkdir -p /etc/consul.d /var/lib/consul
chown -R consul:consul /etc/consul.d /var/lib/consul
chmod 750 /etc/consul.d /var/lib/consul

# Nomad setup
id -u nomad &>/dev/null || useradd --system --home /etc/nomad.d --shell /bin/false nomad
mkdir -p /etc/nomad.d /var/lib/nomad
chown -R nomad:nomad /etc/nomad.d /var/lib/nomad
chmod 750 /etc/nomad.d /var/lib/nomad

echo "==> [7/8] Enabling Systemd services..."
systemctl enable consul
systemctl enable nomad

echo "==> [8/8] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"
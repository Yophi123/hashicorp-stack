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

echo "==> Configuring Consul DNS and SSH certificate trust..."
# Send *.consul lookups to the local Consul agent; everything else is untouched.
install -d -m 0755 /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/consul.conf <<'EOF'
[Resolve]
DNS=127.0.0.1:8600
DNSSEC=false
Domains=~consul
EOF

# Trust certificates signed by Vault's SSH CA. The file starts empty and is
# filled by the timer below once Vault is up.
touch /etc/ssh/trusted-user-ca-keys.pem
chmod 0644 /etc/ssh/trusted-user-ca-keys.pem
cat > /etc/ssh/sshd_config.d/10-vault-ca.conf <<'EOF'
TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
PasswordAuthentication no
EOF

cat > /usr/local/bin/fetch-ssh-ca.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
curl -fsS --max-time 5 http://vault.service.consul:8200/v1/ssh/public_key -o "${tmp}"
grep -q '^ssh-' "${tmp}"
install -m 0644 "${tmp}" /etc/ssh/trusted-user-ca-keys.pem
EOF
chmod 0755 /usr/local/bin/fetch-ssh-ca.sh

cat > /etc/systemd/system/fetch-ssh-ca.service <<'EOF'
[Unit]
Description=Fetch the Vault SSH CA public key
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fetch-ssh-ca.sh
EOF

cat > /etc/systemd/system/fetch-ssh-ca.timer <<'EOF'
[Unit]
Description=Refresh the Vault SSH CA public key

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

systemctl enable fetch-ssh-ca.timer

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

echo "==> [7/8] Leaving services disabled until user data writes their config..."
systemctl disable --now nomad consul
rm -f /etc/nomad.d/nomad.hcl /etc/consul.d/consul.hcl

echo "==> [8/8] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait || true

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

echo "==> [3/5] Installing Vault and consul..."
apt-get update -y
apt-get install -y vault consul


echo "==> [4/6] Leaving services disabled until user data writes their config..."
systemctl disable --now vault consul
rm -f /etc/vault.d/vault.hcl /etc/consul.d/consul.hcl

echo "==> [5/6] Configuring Consul DNS and SSH certificate trust..."

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

echo "==> [6/6] Cleaning up image artifacts..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "==> Installation successfully completed!"
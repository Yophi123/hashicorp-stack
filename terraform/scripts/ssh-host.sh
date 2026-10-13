#!/usr/bin/env bash
# SSH to a host through Boundary, with a one-time certificate Boundary brokers
# from Vault. Nothing is kept: the key and certificate live in a temporary
# directory that is deleted when the session ends.
#
# Needs the Boundary CLI, authenticated (boundary authenticate ...).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ssh-host.sh [options]

  --target NAME       Target name: ssh-server, ssh-vault or ssh-worker
                      (default ssh-worker)                                  [TARGET]
  --scope NAME        Boundary project scope (default infrastructure)       [BOUNDARY_SCOPE]
  --target-id ID      Target id instead of name and scope                   [TARGET_ID]
  --user NAME         Login user on the host (default ubuntu)              [SSH_USER]
  -h, --help          Show this help

Boundary's address comes from BOUNDARY_ADDR, as for the Boundary CLI.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TARGET="${TARGET:-ssh-worker}"
BOUNDARY_SCOPE="${BOUNDARY_SCOPE:-infrastructure}"
TARGET_ID="${TARGET_ID:-}"
SSH_USER="${SSH_USER:-ubuntu}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target)    TARGET="${2:?--target needs a value}"; shift 2 ;;
    --scope)     BOUNDARY_SCOPE="${2:?--scope needs a value}"; shift 2 ;;
    --target-id) TARGET_ID="${2:?--target-id needs a value}"; shift 2 ;;
    --user)      SSH_USER="${2:?--user needs a value}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "unknown option: $1" ;;
  esac
done

for c in boundary jq ssh ssh-keygen; do command -v "$c" >/dev/null || die "$c is not installed"; done
[ -n "${BOUNDARY_ADDR:-}" ] || die "set BOUNDARY_ADDR first, e.g. export BOUNDARY_ADDR=https://boundary.<domain>"

if [ -n "${TARGET_ID}" ]; then
  select_target=(-id "${TARGET_ID}")
  label="${TARGET_ID}"
else
  select_target=(-name "${TARGET}" -scope-name "${BOUNDARY_SCOPE}")
  label="${TARGET} in ${BOUNDARY_SCOPE}"
fi

# One authorization gives both the session and its brokered certificate.
resp=$(boundary targets authorize-session "${select_target[@]}" -format json) \
  || die "Boundary did not authorize a session to ${label}; are you authenticated (boundary authenticate)?"

token=$(jq -r '.item.authorization_token' <<<"${resp}")
cred=$(jq -c '.item.credentials[0].secret.decoded | (.data // .)' <<<"${resp}")
jq -e '.private_key and .signed_key' <<<"${cred}" >/dev/null \
  || die "no SSH certificate was brokered for ${label}; is the target using the ssh-certificate library?"

dir=$(mktemp -d)
trap 'rm -rf "${dir}"' EXIT

jq -r '.private_key' <<<"${cred}" > "${dir}/key"
jq -r '.signed_key'  <<<"${cred}" > "${dir}/key-cert.pub"
chmod 600 "${dir}/key"

printf 'certificate %s for %s, %s\n' \
  "$(jq -r '.serial_number' <<<"${cred}")" "${SSH_USER}" \
  "$(ssh-keygen -L -f "${dir}/key-cert.pub" | awk '/Valid:/ {$1=""; print}')"

# Hosts are replaced often and have no host certificates yet, so their host keys
# are not pinned; that comes with the hardening step.
boundary connect ssh -authz-token "${token}" -username "${SSH_USER}" -- \
  -i "${dir}/key" -o CertificateFile="${dir}/key-cert.pub" -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
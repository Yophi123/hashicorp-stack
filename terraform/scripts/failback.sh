#!/usr/bin/env bash
# Fail the platform back from the pilot-light region to the primary.
#
# Order matters, so traffic never lands on a region that cannot answer and
# Vault never has two writers:
#   1. stop the primary Vault if one is still running (it holds stale data)
#   2. take a fresh snapshot of the pilot-light Vault, stop it, and copy the
#      snapshot into the primary bucket
#   3. start the primary Vault, which restores that snapshot
#   4. start the primary workers and jobs, and wait until they are healthy
#   5. only then stop the pilot-light jobs and scale it back to cold
#
# Every value comes from flags, environment variables or a prompt.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: failback.sh [options]

Required (flag, environment variable, or prompted when run in a terminal):
  --project NAME          Project name used in tags and resource names    [PROJECT]
  --primary-region REGION Region being failed back to                     [PRIMARY_REGION]
  --pilot-region REGION   Pilot-light region being failed back from       [PILOT_REGION]

Optional:
  --workers N             Primary Nomad workers to run (default 1)        [WORKERS]
  --vault-nodes N         Primary Vault nodes to run (default 1)          [VAULT_NODES]
  --job-file PATH         Nomad job to run in the primary; repeatable
  --url URL               Public URL to check once the primary is healthy [APP_URL]
  --skip-vault-data       Do not carry Vault data back; the primary restores
                          from its own last snapshot instead
  --keep-pilot-jobs       Leave the pilot-light region's Nomad jobs registered
  --yes                   Do not ask for confirmation
  -h, --help              Show this help

AWS credentials come from the usual AWS CLI settings (AWS_PROFILE and so on).
EOF
}

log() { printf '%s  %s\n' "$(date -u +%T)" "$*"; }

START=""
die() {
  printf '%s  ERROR: %s\n' "$(date -u +%T)" "$*" >&2
  if [ -n "${START}" ]; then
    printf '%s  stopped %ss after the failback started\n' "$(date -u +%T)" "$(( $(date +%s) - START ))" >&2
  fi
  exit 1
}

PROJECT="${PROJECT:-}"
PRIMARY_REGION="${PRIMARY_REGION:-}"
PILOT_REGION="${PILOT_REGION:-}"
WORKERS="${WORKERS:-1}"
VAULT_NODES="${VAULT_NODES:-1}"
APP_URL="${APP_URL:-}"
JOB_FILES=()
SKIP_VAULT_DATA=0
KEEP_PILOT_JOBS=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)         PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --primary-region)  PRIMARY_REGION="${2:?--primary-region needs a value}"; shift 2 ;;
    --pilot-region)    PILOT_REGION="${2:?--pilot-region needs a value}"; shift 2 ;;
    --workers)         WORKERS="${2:?--workers needs a value}"; shift 2 ;;
    --vault-nodes)     VAULT_NODES="${2:?--vault-nodes needs a value}"; shift 2 ;;
    --job-file)        JOB_FILES+=("${2:?--job-file needs a value}"); shift 2 ;;
    --url)             APP_URL="${2:?--url needs a value}"; shift 2 ;;
    --skip-vault-data) SKIP_VAULT_DATA=1; shift ;;
    --keep-pilot-jobs) KEEP_PILOT_JOBS=1; shift ;;
    --yes)             ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "unknown option: $1" ;;
  esac
done

# ask VAR "question": fill a missing value interactively, or fail when not in a terminal.
ask() {
  local var="$1" question="$2" value
  [ -n "${!var:-}" ] && return 0
  [ -t 0 ] || die "missing ${var}: pass it as a flag or environment variable (see --help)"
  read -r -p "${question}: " value
  [ -n "${value}" ] || die "${var} is required"
  printf -v "${var}" '%s' "${value}"
}

ask PROJECT        "Project name"
ask PRIMARY_REGION "Primary region (failing back to)"
ask PILOT_REGION   "Pilot-light region (failing back from)"

region_re='^[a-z]{2}(-[a-z]+)+-[0-9]+$'
[[ "${PRIMARY_REGION}" =~ ${region_re} ]] || die "not a region name: ${PRIMARY_REGION}"
[[ "${PILOT_REGION}" =~ ${region_re} ]]   || die "not a region name: ${PILOT_REGION}"
[ "${PRIMARY_REGION}" != "${PILOT_REGION}" ] || die "primary and pilot-light regions must differ"
[[ "${WORKERS}" =~ ^[1-9][0-9]*$ ]]     || die "--workers must be a positive whole number"
[[ "${VAULT_NODES}" =~ ^(1|3|5)$ ]]     || die "--vault-nodes must be 1, 3 or 5"
if [ -n "${APP_URL}" ] && ! [[ "${APP_URL}" =~ ^https?://[^/]+ ]]; then
  die "--url must start with http:// or https://, got: ${APP_URL}"
fi
for f in ${JOB_FILES[@]+"${JOB_FILES[@]}"}; do [ -r "${f}" ] || die "cannot read job file: ${f}"; done
command -v aws >/dev/null || die "the AWS CLI is not installed"
command -v jq >/dev/null  || die "jq is not installed"

LOG_FILE="failback-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Commands run on nodes through Systems Manager.
read -r -d '' REMOTE_VAULT_STATE <<'EOF' || true
state=$(systemctl show vault-bootstrap -p ActiveState --value)
seal=$(curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq -r '"\(.initialized) \(.sealed)"')
marker=clear; [ -f /opt/vault/.restore-pending ] && marker=pending
echo "${state} ${seal:-unreachable unreachable} ${marker}"
EOF

read -r -d '' REMOTE_VAULT_LOG <<'EOF' || true
journalctl -u vault-bootstrap --no-pager | grep '==>' | tail -n 5
EOF

read -r -d '' REMOTE_VAULT_SNAPSHOT <<'EOF' || true
systemctl start vault-snapshot && journalctl -u vault-snapshot --no-pager -n 5 | grep '==>'
EOF

read -r -d '' REMOTE_READY_WORKERS <<'EOF' || true
nomad node status -json | jq '[.[] | select(.Status == "ready")] | length'
EOF

read -r -d '' REMOTE_STOP_ALL_JOBS <<'EOF' || true
for id in $(curl -s http://127.0.0.1:4646/v1/jobs | jq -r '.[] | select(.Status != "dead") | .ID'); do
  nomad job stop -detach "${id}" >/dev/null && echo "stopped ${id}"
done
EOF

## AWS helpers; every one takes the region first

asg_name() {   # asg_name <region> <role>
  aws autoscaling describe-auto-scaling-groups --region "$1" \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '${PROJECT}-$2-')].AutoScalingGroupName | [0]" \
    --output text
}

in_service_instance() {   # in_service_instance <region> <asg>
  aws autoscaling describe-auto-scaling-groups --region "$1" --auto-scaling-group-names "$2" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" --output text
}

instance_count() {   # instance_count <region> <asg>: instances in any state
  aws autoscaling describe-auto-scaling-groups --region "$1" --auto-scaling-group-names "$2" \
    --query "length(AutoScalingGroups[0].Instances)" --output text
}

server_instance() {   # server_instance <region>
  aws ec2 describe-instances --region "$1" \
    --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Role,Values=nomad_consul_server" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text
}

snapshot_bucket() {   # snapshot_bucket <region>
  aws s3api list-buckets --region "$1" --prefix "${PROJECT}-snapshots-" --bucket-region "$1" \
    --query 'Buckets[0].Name' --output text
}

found() { [ -n "$1" ] && [ "$1" != "None" ]; }

# ssm_run <region> <instance-id> <script>: run a shell script on a node and print its output.
ssm_run() {
  local region="$1" iid="$2" script="$3" cid status
  cid=$(aws ssm send-command --region "${region}" --instance-ids "${iid}" \
          --document-name AWS-RunShellScript \
          --parameters "$(jq -cn --arg c "${script}" '{commands: [$c]}')" \
          --query Command.CommandId --output text 2>/dev/null) || return 1
  for _ in $(seq 1 60); do
    sleep 3
    status=$(aws ssm get-command-invocation --region "${region}" --command-id "${cid}" \
               --instance-id "${iid}" --query Status --output text 2>/dev/null) || continue
    case "${status}" in
      Success)
        aws ssm get-command-invocation --region "${region}" --command-id "${cid}" \
          --instance-id "${iid}" --query StandardOutputContent --output text
        return 0 ;;
      Failed|Cancelled|TimedOut|Undeliverable|Terminated)
        aws ssm get-command-invocation --region "${region}" --command-id "${cid}" \
          --instance-id "${iid}" --query StandardErrorContent --output text >&2 || true
        return 1 ;;
    esac
  done
  return 1
}

# wait_for <description> <timeout seconds> <command...>
wait_for() {
  local desc="$1" timeout="$2" start
  shift 2
  start=$(date +%s)
  log "waiting: ${desc}"
  until "$@"; do
    [ $(( $(date +%s) - start )) -lt "${timeout}" ] || die "timed out after ${timeout}s: ${desc}"
    sleep 10
  done
  log "ready:   ${desc} ($(( $(date +%s) - start ))s)"
}

## Readiness checks

group_empty() {   # group_empty <region> <asg>
  [ "$(instance_count "$1" "$2")" = "0" ]
}

primary_vault_restored() {
  local iid out state initialized sealed marker
  iid=$(in_service_instance "${PRIMARY_REGION}" "${PRIMARY_VAULT_ASG}")
  found "${iid}" || return 1
  out=$(ssm_run "${PRIMARY_REGION}" "${iid}" "${REMOTE_VAULT_STATE}") || return 1
  read -r state initialized sealed marker <<<"${out}"
  case "${state}" in
    failed) ssm_run "${PRIMARY_REGION}" "${iid}" "${REMOTE_VAULT_LOG}" || true
            die "the primary Vault's init/restore job failed on ${iid}" ;;
    active) if [ "${initialized}" = "false" ]; then
              ssm_run "${PRIMARY_REGION}" "${iid}" "${REMOTE_VAULT_LOG}" || true
              die "the primary Vault came up uninitialized: no snapshot was found to restore"
            fi ;;
  esac
  [ "${state}" = "active" ] && [ "${initialized}" = "true" ] && [ "${sealed}" = "false" ] && [ "${marker}" = "clear" ] || return 1
  PRIMARY_VAULT_INSTANCE="${iid}"
}

primary_workers_ready() {
  local n
  n=$(ssm_run "${PRIMARY_REGION}" "${PRIMARY_SERVER}" "${REMOTE_READY_WORKERS}") || return 1
  [ "${n:-0}" -ge "${WORKERS}" ] 2>/dev/null
}

primary_targets_healthy() {
  local tg healthy
  for tg in ${PRIMARY_TARGET_GROUPS}; do
    healthy=$(aws elbv2 describe-target-health --region "${PRIMARY_REGION}" --target-group-arn "${tg}" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
    [ "${healthy:-0}" -ge 1 ] || return 1
  done
}

url_ok() { curl -fsS -o /dev/null --max-time 5 "${APP_URL}"; }

## Preflight: both regions must answer

log "failback: ${PROJECT}, ${PILOT_REGION} -> ${PRIMARY_REGION}   (log: ${LOG_FILE})"
log "caller:   $(aws sts get-caller-identity --query Arn --output text)"

PRIMARY_VAULT_ASG=$(asg_name "${PRIMARY_REGION}" vault)
PRIMARY_WORKER_ASG=$(asg_name "${PRIMARY_REGION}" nomad_worker)
PRIMARY_SERVER=$(server_instance "${PRIMARY_REGION}")
PILOT_VAULT_ASG=$(asg_name "${PILOT_REGION}" vault)
PILOT_WORKER_ASG=$(asg_name "${PILOT_REGION}" nomad_worker)
PILOT_SERVER=$(server_instance "${PILOT_REGION}")
for v in PRIMARY_VAULT_ASG PRIMARY_WORKER_ASG PRIMARY_SERVER PILOT_VAULT_ASG PILOT_WORKER_ASG PILOT_SERVER; do
  found "${!v}" || die "could not find ${v} for project ${PROJECT}; is that region up?"
done
PRIMARY_TARGET_GROUPS=$(aws autoscaling describe-load-balancer-target-groups --region "${PRIMARY_REGION}" \
  --auto-scaling-group-name "${PRIMARY_WORKER_ASG}" \
  --query 'LoadBalancerTargetGroups[].LoadBalancerTargetGroupARN' --output text)

PILOT_VAULT_INSTANCE=$(in_service_instance "${PILOT_REGION}" "${PILOT_VAULT_ASG}")
if [ "${SKIP_VAULT_DATA}" -eq 0 ]; then
  found "${PILOT_VAULT_INSTANCE}" || die "no Vault is running in ${PILOT_REGION}; pass --skip-vault-data to restore the primary from its own last snapshot"
  PRIMARY_BUCKET=$(snapshot_bucket "${PRIMARY_REGION}")
  PILOT_BUCKET=$(snapshot_bucket "${PILOT_REGION}")
  found "${PRIMARY_BUCKET}" || die "no snapshot bucket found in ${PRIMARY_REGION}"
  found "${PILOT_BUCKET}"   || die "no snapshot bucket found in ${PILOT_REGION}"
  vault_plan="snapshot ${PILOT_REGION} Vault, copy to s3://${PRIMARY_BUCKET}"
else
  vault_plan="skipped: the primary restores its own last snapshot"
fi

cat <<EOF

  Vault data:               ${vault_plan}
  Primary Vault group:      ${PRIMARY_VAULT_ASG} -> ${VAULT_NODES}
  Primary worker group:     ${PRIMARY_WORKER_ASG} -> ${WORKERS}
  Jobs to run in primary:   ${JOB_FILES[*]:-none}
  Pilot-light jobs:         $([ "${KEEP_PILOT_JOBS}" -eq 1 ] && echo "kept" || echo "stopped")
  Pilot-light groups:       ${PILOT_VAULT_ASG}, ${PILOT_WORKER_ASG} -> 0
  URL to check:             ${APP_URL:-none}

  Vault is unavailable from the pilot-light snapshot until the primary Vault
  has restored it. Anything written to Vault in that window is lost.

EOF
if [ "${ASSUME_YES}" -ne 1 ]; then
  [ -t 0 ] || die "refusing to run unattended without --yes"
  read -r -p "Proceed with failback? [y/N] " answer
  [ "${answer}" = "y" ] || [ "${answer}" = "Y" ] || die "aborted"
fi

START=$(date +%s)
log "started"

## 1. No stale primary Vault

if ! group_empty "${PRIMARY_REGION}" "${PRIMARY_VAULT_ASG}"; then
  aws autoscaling update-auto-scaling-group --region "${PRIMARY_REGION}" \
    --auto-scaling-group-name "${PRIMARY_VAULT_ASG}" --min-size 0 --desired-capacity 0
  wait_for "stale primary Vault stopped" 600 group_empty "${PRIMARY_REGION}" "${PRIMARY_VAULT_ASG}"
fi

## 2. Carry Vault's data back

if [ "${SKIP_VAULT_DATA}" -eq 0 ]; then
  VAULT_DOWN=$(date +%s)
  log "taking a final snapshot of the ${PILOT_REGION} Vault"
  ssm_run "${PILOT_REGION}" "${PILOT_VAULT_INSTANCE}" "${REMOTE_VAULT_SNAPSHOT}" | sed 's/^/          /' \
    || die "the final snapshot failed; nothing has been changed in ${PILOT_REGION}"

  aws autoscaling set-desired-capacity --region "${PILOT_REGION}" \
    --auto-scaling-group-name "${PILOT_VAULT_ASG}" --desired-capacity 0
  log "stopped the ${PILOT_REGION} Vault; Vault writes are now unavailable"

  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  for key in "vault/history/${stamp}-failback.snap" "vault/latest.snap"; do
    aws s3 cp --only-show-errors --source-region "${PILOT_REGION}" --region "${PRIMARY_REGION}" \
      "s3://${PILOT_BUCKET}/vault/latest.snap" "s3://${PRIMARY_BUCKET}/${key}" \
      || die "could not copy the snapshot to s3://${PRIMARY_BUCKET}/${key}"
  done
  log "copied the snapshot to s3://${PRIMARY_BUCKET}/vault/latest.snap"
fi

## 3. Primary Vault restores it

aws autoscaling update-auto-scaling-group --region "${PRIMARY_REGION}" \
  --auto-scaling-group-name "${PRIMARY_VAULT_ASG}" --min-size "${VAULT_NODES}" --desired-capacity "${VAULT_NODES}"
wait_for "primary Vault restored and unsealed" 1200 primary_vault_restored
ssm_run "${PRIMARY_REGION}" "${PRIMARY_VAULT_INSTANCE}" "${REMOTE_VAULT_LOG}" | sed 's/^/          /' || true
if [ -n "${VAULT_DOWN:-}" ]; then
  log "Vault was unavailable for $(( $(date +%s) - VAULT_DOWN ))s"
fi

## 4. Primary workloads, healthy before any traffic moves

aws autoscaling update-auto-scaling-group --region "${PRIMARY_REGION}" \
  --auto-scaling-group-name "${PRIMARY_WORKER_ASG}" --desired-capacity "${WORKERS}"
wait_for "${WORKERS} primary Nomad worker(s) ready" 900 primary_workers_ready

for f in ${JOB_FILES[@]+"${JOB_FILES[@]}"}; do
  log "submitting $(basename "${f}") to ${PRIMARY_REGION}"
  b64=$(base64 < "${f}" | tr -d '\n')
  ssm_run "${PRIMARY_REGION}" "${PRIMARY_SERVER}" \
    "printf '%s' '${b64}' | base64 -d > /tmp/failback-job.nomad.hcl && nomad job run -detach /tmp/failback-job.nomad.hcl" \
    | sed 's/^/          /' || die "could not submit ${f}"
done

if [ -n "${PRIMARY_TARGET_GROUPS}" ]; then
  wait_for "primary load balancer targets healthy" 600 primary_targets_healthy
  log "traffic can return to ${PRIMARY_REGION}: $(( $(date +%s) - START ))s after the start"
fi
if [ -n "${APP_URL}" ]; then
  wait_for "${APP_URL} answering" 600 url_ok
fi

## 5. Pilot light back to cold

if [ "${KEEP_PILOT_JOBS}" -eq 0 ]; then
  log "stopping Nomad jobs in ${PILOT_REGION}"
  ssm_run "${PILOT_REGION}" "${PILOT_SERVER}" "${REMOTE_STOP_ALL_JOBS}" | sed 's/^/          /' \
    || log "WARNING: could not stop the pilot-light jobs; stop them by hand"
fi
aws autoscaling set-desired-capacity --region "${PILOT_REGION}" \
  --auto-scaling-group-name "${PILOT_WORKER_ASG}" --desired-capacity 0
aws autoscaling set-desired-capacity --region "${PILOT_REGION}" \
  --auto-scaling-group-name "${PILOT_VAULT_ASG}" --desired-capacity 0
log "scaled the ${PILOT_REGION} workers and Vault to zero"

END=$(date +%s)
log "complete"
cat <<EOF

  Failback time:   $(( (END - START) / 60 ))m $(( (END - START) % 60 ))s
  Log:             ${LOG_FILE}

  Run terraform apply afterwards to put the primary groups' minimum sizes
  back to their configured values.

EOF
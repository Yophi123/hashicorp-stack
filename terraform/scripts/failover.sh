#!/usr/bin/env bash
# Fail the platform over to the pilot-light region.
#
# Talks only to the pilot-light region's AWS APIs (plus one optional,
# time-limited check of the primary), so it works when the primary region is
# unavailable. Every value comes from flags, environment variables or a prompt;
# nothing about the deployment is hard-coded.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: failover.sh [options]

Required (flag, environment variable, or prompted when run in a terminal):
  --project NAME          Project name used in tags and resource names    [PROJECT]
  --primary-region REGION Region being failed away from                   [PRIMARY_REGION]
  --pilot-region REGION   Pilot-light region being failed over to         [PILOT_REGION]

Optional:
  --workers N             Nomad workers to start (default 1)              [WORKERS]
  --job-file PATH         Nomad job to run in the pilot-light region; repeatable
  --url URL               Public URL to wait for once traffic has moved   [APP_URL]
  --force                 Continue even if the primary Vault still looks active
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
    printf '%s  stopped %ss after the failover started\n' "$(date -u +%T)" "$(( $(date +%s) - START ))" >&2
  fi
  exit 1
}

PROJECT="${PROJECT:-}"
PRIMARY_REGION="${PRIMARY_REGION:-}"
PILOT_REGION="${PILOT_REGION:-}"
WORKERS="${WORKERS:-1}"
APP_URL="${APP_URL:-}"
JOB_FILES=()
FORCE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT="${2:?--project needs a value}"; shift 2 ;;
    --primary-region) PRIMARY_REGION="${2:?--primary-region needs a value}"; shift 2 ;;
    --pilot-region)   PILOT_REGION="${2:?--pilot-region needs a value}"; shift 2 ;;
    --workers)        WORKERS="${2:?--workers needs a value}"; shift 2 ;;
    --job-file)       JOB_FILES+=("${2:?--job-file needs a value}"); shift 2 ;;
    --url)            APP_URL="${2:?--url needs a value}"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    --yes)            ASSUME_YES=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown option: $1" ;;
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
ask PRIMARY_REGION "Primary region (failing away from)"
ask PILOT_REGION   "Pilot-light region (failing over to)"

region_re='^[a-z]{2}(-[a-z]+)+-[0-9]+$'
[[ "${PRIMARY_REGION}" =~ ${region_re} ]] || die "not a region name: ${PRIMARY_REGION}"
[[ "${PILOT_REGION}" =~ ${region_re} ]]   || die "not a region name: ${PILOT_REGION}"
[ "${PRIMARY_REGION}" != "${PILOT_REGION}" ] || die "primary and pilot-light regions must differ"
[[ "${WORKERS}" =~ ^[1-9][0-9]*$ ]] || die "--workers must be a positive whole number"
if [ -n "${APP_URL}" ] && ! [[ "${APP_URL}" =~ ^https?://[^/]+ ]]; then
  die "--url must start with http:// or https://, got: ${APP_URL}"
fi
for f in ${JOB_FILES[@]+"${JOB_FILES[@]}"}; do [ -r "${f}" ] || die "cannot read job file: ${f}"; done
command -v aws >/dev/null || die "the AWS CLI is not installed"
command -v jq >/dev/null  || die "jq is not installed"

LOG_FILE="failover-$(date -u +%Y%m%dT%H%M%SZ).log"
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

read -r -d '' REMOTE_READY_WORKERS <<'EOF' || true
nomad node status -json | jq '[.[] | select(.Status == "ready")] | length'
EOF

## AWS helpers (pilot-light region unless stated)

asg_name() {   # asg_name <region> <role>
  aws autoscaling describe-auto-scaling-groups --region "$1" \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '${PROJECT}-$2-')].AutoScalingGroupName | [0]" \
    --output text
}

in_service_instance() {   # in_service_instance <asg>
  aws autoscaling describe-auto-scaling-groups --region "${PILOT_REGION}" --auto-scaling-group-names "$1" \
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId | [0]" --output text
}

server_instance() {
  aws ec2 describe-instances --region "${PILOT_REGION}" \
    --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Role,Values=nomad_consul_server" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text
}

# ssm_run <instance-id> <script>: run a shell script on a node and print its output.
ssm_run() {
  local iid="$1" script="$2" cid status
  cid=$(aws ssm send-command --region "${PILOT_REGION}" --instance-ids "${iid}" \
          --document-name AWS-RunShellScript \
          --parameters "$(jq -cn --arg c "${script}" '{commands: [$c]}')" \
          --query Command.CommandId --output text 2>/dev/null) || return 1
  for _ in $(seq 1 40); do
    sleep 3
    status=$(aws ssm get-command-invocation --region "${PILOT_REGION}" --command-id "${cid}" \
               --instance-id "${iid}" --query Status --output text 2>/dev/null) || continue
    case "${status}" in
      Success)
        aws ssm get-command-invocation --region "${PILOT_REGION}" --command-id "${cid}" \
          --instance-id "${iid}" --query StandardOutputContent --output text
        return 0 ;;
      Failed|Cancelled|TimedOut|Undeliverable|Terminated)
        aws ssm get-command-invocation --region "${PILOT_REGION}" --command-id "${cid}" \
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

vault_restored() {
  local iid out state initialized sealed marker
  iid=$(in_service_instance "${VAULT_ASG}")
  [ -n "${iid}" ] && [ "${iid}" != "None" ] || return 1
  out=$(ssm_run "${iid}" "${REMOTE_VAULT_STATE}") || return 1   # agent may not be registered yet
  read -r state initialized sealed marker <<<"${out}"
  case "${state}" in
    failed) ssm_run "${iid}" "${REMOTE_VAULT_LOG}" || true
            die "Vault's init/restore job failed on ${iid}" ;;
    active) if [ "${initialized}" = "false" ]; then
              ssm_run "${iid}" "${REMOTE_VAULT_LOG}" || true
              die "Vault came up uninitialized: no snapshot was found to restore"
            fi ;;
  esac
  [ "${state}" = "active" ] && [ "${initialized}" = "true" ] && [ "${sealed}" = "false" ] && [ "${marker}" = "clear" ] || return 1
  VAULT_INSTANCE="${iid}"
}

workers_ready() {
  local n
  n=$(ssm_run "${SERVER_INSTANCE}" "${REMOTE_READY_WORKERS}") || return 1
  [ "${n:-0}" -ge "${WORKERS}" ] 2>/dev/null
}

targets_healthy() {
  local tg healthy
  for tg in ${TARGET_GROUPS}; do
    healthy=$(aws elbv2 describe-target-health --region "${PILOT_REGION}" --target-group-arn "${tg}" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
    [ "${healthy:-0}" -ge 1 ] || return 1
  done
}

url_ok() { curl -fsS -o /dev/null --max-time 5 "${APP_URL}"; }

## Preflight

log "failover: ${PROJECT}, ${PRIMARY_REGION} -> ${PILOT_REGION}   (log: ${LOG_FILE})"
log "caller:   $(aws sts get-caller-identity --query Arn --output text)"

VAULT_ASG=$(asg_name "${PILOT_REGION}" vault)
WORKER_ASG=$(asg_name "${PILOT_REGION}" nomad_worker)
SERVER_INSTANCE=$(server_instance)
for v in VAULT_ASG WORKER_ASG SERVER_INSTANCE; do
  [ -n "${!v}" ] && [ "${!v}" != "None" ] || die "could not find ${v} in ${PILOT_REGION} for project ${PROJECT}"
done
TARGET_GROUPS=$(aws autoscaling describe-load-balancer-target-groups --region "${PILOT_REGION}" \
  --auto-scaling-group-name "${WORKER_ASG}" \
  --query 'LoadBalancerTargetGroups[].LoadBalancerTargetGroupARN' --output text)

# Vault's data comes from the newest snapshot copied into the pilot-light bucket.
BUCKET=$(aws s3api list-buckets --region "${PILOT_REGION}" --prefix "${PROJECT}-snapshots-" \
  --bucket-region "${PILOT_REGION}" --query 'Buckets[0].Name' --output text)
[ -n "${BUCKET}" ] && [ "${BUCKET}" != "None" ] || die "no snapshot bucket found in ${PILOT_REGION}"
SNAPSHOT_TIME=$(aws s3api head-object --region "${PILOT_REGION}" --bucket "${BUCKET}" \
  --key vault/latest.snap --query LastModified --output text 2>/dev/null) \
  || die "no Vault snapshot in s3://${BUCKET}/vault/latest.snap"

# Two active Vaults would overwrite each other's snapshots. The primary's API
# is asked once, briefly; in a real outage it will not answer, and that is fine.
primary_vaults=$(aws autoscaling describe-auto-scaling-groups --region "${PRIMARY_REGION}" \
  --cli-connect-timeout 5 --cli-read-timeout 10 \
  --query "length(AutoScalingGroups[?starts_with(AutoScalingGroupName, '${PROJECT}-vault-')].Instances[] | [?LifecycleState=='InService'])" \
  --output text 2>/dev/null) || primary_vaults="unknown"
case "${primary_vaults}" in
  0)       log "primary:  no Vault instance in service" ;;
  unknown) log "primary:  ${PRIMARY_REGION} did not answer; assuming it is down" ;;
  *)       [ "${FORCE}" -eq 1 ] || die "the primary Vault still has ${primary_vaults} instance(s) in service; stop it first or pass --force"
           log "primary:  Vault still in service, continuing because of --force" ;;
esac

cat <<EOF

  Pilot-light Vault group:  ${VAULT_ASG} -> 1 instance
  Pilot-light worker group: ${WORKER_ASG} -> ${WORKERS} instance(s)
  Vault data as of:         ${SNAPSHOT_TIME}
  Jobs to run:              ${JOB_FILES[*]:-none}
  Target groups:            $(echo "${TARGET_GROUPS}" | wc -w | tr -d ' ')
  URL to check:             ${APP_URL:-none}

EOF
if [ "${ASSUME_YES}" -ne 1 ]; then
  [ -t 0 ] || die "refusing to run unattended without --yes"
  read -r -p "Proceed with failover? [y/N] " answer
  [ "${answer}" = "y" ] || [ "${answer}" = "Y" ] || die "aborted"
fi

## Failover

START=$(date +%s)
log "started"

aws autoscaling set-desired-capacity --region "${PILOT_REGION}" --auto-scaling-group-name "${VAULT_ASG}" --desired-capacity 1
aws autoscaling set-desired-capacity --region "${PILOT_REGION}" --auto-scaling-group-name "${WORKER_ASG}" --desired-capacity "${WORKERS}"
log "scaled up Vault and workers"

wait_for "Vault restored and unsealed" 1200 vault_restored
ssm_run "${VAULT_INSTANCE}" "${REMOTE_VAULT_LOG}" | sed 's/^/          /' || true

wait_for "${WORKERS} Nomad worker(s) ready" 900 workers_ready

for f in ${JOB_FILES[@]+"${JOB_FILES[@]}"}; do
  log "submitting $(basename "${f}")"
  b64=$(base64 < "${f}" | tr -d '\n')
  ssm_run "${SERVER_INSTANCE}" "printf '%s' '${b64}' | base64 -d > /tmp/failover-job.nomad.hcl && nomad job run -detach /tmp/failover-job.nomad.hcl" \
    | sed 's/^/          /' || die "could not submit ${f}"
done

if [ -n "${TARGET_GROUPS}" ]; then
  wait_for "load balancer targets healthy" 600 targets_healthy
  log "traffic can reach ${PILOT_REGION}: $(( $(date +%s) - START ))s after the start"
fi
if [ -n "${APP_URL}" ]; then
  wait_for "${APP_URL} answering" 600 url_ok
fi

END=$(date +%s)
snap_epoch=$(jq -rn --arg t "${SNAPSHOT_TIME}" '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601')

log "complete"
cat <<EOF

  Recovery time:       $(( (END - START) / 60 ))m $(( (END - START) % 60 ))s  (from scale-up to ready)
  Vault data age:      $(( (START - snap_epoch) / 60 ))m $(( (START - snap_epoch) % 60 ))s at the start of failover
  Log:                 ${LOG_FILE}

EOF
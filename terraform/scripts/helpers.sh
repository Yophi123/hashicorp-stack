# Source this file:  source scripts/helpers.sh
# Needs PROJECT, PRIMARY_REGION and PILOT_REGION in the environment.

_need_env() {
  local v val missing=0
  for v in PROJECT PRIMARY_REGION PILOT_REGION; do
    eval "val=\${$v:-}"        # indirect lookup that works in bash and zsh
    if [ -z "$val" ]; then echo "set $v first (export $v=...)" >&2; missing=1; fi
  done
  return "$missing"
}

# node_id <region> <role>   roles: nomad_consul_server, nomad_worker, vault, boundary
node_id() {
  _need_env || return 1
  aws ec2 describe-instances --region "$1" \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=tag:Role,Values=$2" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

# shell <region> <role>
shell() { _need_env || return 1; aws ssm start-session --region "$1" --target "$(node_id "$1" "$2")"; }

# asg <region> <role>
asg() {
  _need_env || return 1
  aws autoscaling describe-auto-scaling-groups --region "$1" \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '$PROJECT-$2-')].AutoScalingGroupName | [0]" \
    --output text
}

# bucket <region>
bucket() {
  _need_env || return 1
  aws s3api list-buckets --region "$1" --prefix "$PROJECT-snapshots-" --bucket-region "$1" \
    --query 'Buckets[0].Name' --output text
}

# secret <vault|boundary> [region]
secret() {
  _need_env || return 1
  local region="${2:-$PRIMARY_REGION}" arn
  arn=$(aws secretsmanager list-secrets --region "$region" \
    --filters Key=name,Values="$PROJECT/$1/init-" \
    --query 'sort_by(SecretList, &CreatedDate)[-1].ARN' --output text)
  aws secretsmanager get-secret-value --region "$region" --secret-id "$arn" \
    --query SecretString --output text
}

# replace <region> <role>
replace() {
  _need_env || return 1
  date -u
  aws autoscaling terminate-instance-in-auto-scaling-group --region "$1" \
    --instance-id "$(node_id "$1" "$2")" --no-should-decrement-desired-capacity
}

# alb_dns <region>
alb_dns() {
  _need_env || return 1
  aws elbv2 describe-load-balancers --region "$1" --names "$PROJECT-alb" \
    --query 'LoadBalancers[0].DNSName' --output text
}

# tg_health <region> [name prefix, default whoami]
tg_health() {
  _need_env || return 1
  local arn
  arn=$(aws elbv2 describe-target-groups --region "$1" \
    --query "TargetGroups[?starts_with(TargetGroupName, '${2:-whoami}')].TargetGroupArn | [0]" --output text)
  aws elbv2 describe-target-health --region "$1" --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].[Target.Id, TargetHealth.State]' --output text
}
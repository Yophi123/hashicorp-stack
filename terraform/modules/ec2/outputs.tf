output "security_group_ids" {
  description = "Security group ID per node group."
  value       = { for k, sg in aws_security_group.node : k => sg.id }
}

output "iam_role_arns" {
  description = "Instance role ARN per node group. Used for Vault AWS auth bindings."
  value       = { for k, r in aws_iam_role.node : k => r.arn }
}

output "iam_role_names" {
  description = "Instance role name per node group, for attaching extra policies from outside the module."
  value       = { for k, r in aws_iam_role.node : k => r.name }
}

output "autoscaling_group_names" {
  description = "ASG name per node group. The failover script scales these with the AWS CLI."
  value       = { for k, asg in aws_autoscaling_group.node : k => asg.name }
}

output "ami_ids" {
  description = "AMI each node group currently launches from."
  value       = { for k, ami in data.aws_ami.node : k => ami.id }
}

output "join_tag" {
  description = "Cloud auto-join tag: the key, and the value per node group. Also usable as a Boundary host catalog filter."
  value = {
    key    = var.retry_join_tag_key
    values = { for k in local.groups : k => "${var.project_name}-${k}" }
  }
}

output "ports" {
  description = "Port numbers for every product. The alb module reads these for its target groups and health checks."
  value       = local.ports
}
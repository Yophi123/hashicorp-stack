## Load Balancer 
output "external_nlb_dns_name" {
  value       = aws_lb.external.dns_name
  description = <<-EOT
    Internet-facing NLB hostname. This is the address you point the Boundary
    client at: BOUNDARY_ADDR=http://<this>:9200. It is also what Boundary
    workers advertise as public_addr, so it ends up in session handshakes.
  EOT
}

output "external_nlb_zone_id" {
  value       = aws_lb.external.zone_id
  description = "Hosted zone ID of the external NLB, for an alias record in a public zone."
}

output "external_nlb_arn" {
  value       = aws_lb.external.arn
  description = "ARN of the internet-facing NLB."
}

output "internal_nlb_dns_name" {
  value       = aws_lb.internal.dns_name
  description = "Internal NLB hostname. Prefer the service FQDNs below over this."
}

output "internal_nlb_zone_id" {
  value       = aws_lb.internal.zone_id
  description = "Hosted zone ID of the internal NLB."
}

output "internal_nlb_arn" {
  value       = aws_lb.internal.arn
  description = "ARN of the internal NLB."
}

## Service Address
output "service_fqdns" {
  value = {
    for k, r in aws_route53_record.service : k => r.fqdn
  }
  description = <<-EOT
    Private FQDN per service, keyed vault / consul / nomad / boundary. These
    resolve only inside the VPC. Feed them to TLS SANs and to Boundary target
    definitions rather than hardcoding the NLB hostname.
  EOT
}

output "service_endpoints" {
  value = {
    for k, s in local.internal_services :
    k => "http://${aws_route53_record.service[k].fqdn}:${s.port}"
  }
  description = <<-EOT
    Scheme + host + port per service, as reachable from inside the VPC.
    Scheme is http because the bootstrap config runs with tls_disable; this
    output changes to https once TLS is in place, so treat it as the single
    place downstream modules read the address from.
  EOT
}

output "vault_addr" {
  value       = "http://${aws_route53_record.service["vault"].fqdn}:${local.ports.vault.api}"
  description = "Convenience output for VAULT_ADDR on instances inside the VPC."
}

## Security groups
output "security_group_ids" {
  value = {
    for k, sg in aws_security_group.node : k => sg.id
  }
  description = <<-EOT
    Instance security group ID per node group. Later modules reference these
    as the source of their own ingress rules rather than widening to the VPC
    CIDR — e.g. an ElastiCache module allowing only nomad_worker.
  EOT
}

output "external_nlb_security_group_id" {
  value       = aws_security_group.nlb_external.id
  description = "Security group attached to the internet-facing NLB."
}

## EC2 & ASG
output "autoscaling_group_names" {
  value = {
    for k, asg in aws_autoscaling_group.node : k => asg.name
  }
  description = <<-EOT
    ASG name per node group. Needed for `aws autoscaling
    start-instance-refresh` while instance_refresh_enabled is false, and for
    attaching scaling policies from a separate module.
  EOT
}

output "autoscaling_group_arns" {
  value = {
    for k, asg in aws_autoscaling_group.node : k => asg.arn
  }
  description = "ASG ARN per node group, for IAM conditions and EventBridge rules."
}

output "launch_template_ids" {
  value = {
    for k, lt in aws_launch_template.node : k => lt.id
  }
  description = "Launch template ID per node group."
}

output "iam_role_names" {
  value = {
    for k, r in aws_iam_role.node : k => r.name
  }
  description = <<-EOT
    Instance role name per node group, so other modules can attach policies
    without this module knowing about them. Vault's AWS auth method also
    needs the ARNs below.
  EOT
}

output "iam_role_arns" {
  value = {
    for k, r in aws_iam_role.node : k => r.arn
  }
  description = "Instance role ARN per node group. Bind these to Vault roles for IAM auth."
}

output "ami_ids" {
  value = {
    for k, a in data.aws_ami.ami_ids : k => a.id
  }
  description = <<-EOT
    AMI actually selected per node group. Worth surfacing because most_recent
    resolves at plan time — this is how you see which Packer build a given
    apply pinned.
  EOT
}

## Target groups
output "target_group_arns" {
  value = merge(
    { for k, tg in aws_lb_target_group.internal : "internal_${k}" => tg.arn },
    { for k, tg in aws_lb_target_group.external : "external_${k}" => tg.arn },
  )
  description = "Target group ARNs, prefixed internal_ / external_."
}

output "vault_init_secret_arn" {
  value       = try(aws_secretsmanager_secret.vault_init[0].arn, null)
  description = "Recovery keys and root token land here after first boot."
}

output "boundary_init_secret_arn" {
  value       = try(aws_secretsmanager_secret.boundary_init[0].arn, null)
  description = "Initial Boundary admin credentials land here after first boot."
}
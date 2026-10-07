output "target_group_arns" {
  description = "Target group ARNs keyed by node group, in the shape the ec2 module expects."
  value = {
    for g in distinct([for s in var.services : s.node_group]) :
    g => [for k, s in var.services : aws_lb_target_group.service[k].arn if s.node_group == g]
  }
}

output "service_urls" {
  description = "HTTPS URL per published service."
  value       = { for k, fqdn in local.fqdns : k => "https://${fqdn}" }
}

output "https_listener_arn" {
  description = "HTTPS listener ARN, for adding application routing rules later."
  value       = aws_lb_listener.https.arn
}

output "security_group_id" {
  description = "Security group attached to the ALB."
  value       = aws_security_group.alb.id
}

output "dns_name" {
  description = "The ALB's own DNS name."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "The ALB's hosted zone ID, for alias records."
  value       = aws_lb.this.zone_id
}
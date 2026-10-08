output "hashicorp_stack_domain" {
  value = data.aws_route53_zone.public.name
}

output "ami_ids" {
  value = data.aws_ami_ids.hashicorp_stack_amis.ids
}

output "boundary" {
  value = data.aws_route53_zone.public.name
}

output "boundary_url" {
  description = "Boundary UI and API address. Use as BOUNDARY_ADDR."
  value       = module.alb.service_urls["boundary"]
}

output "boundary_init_secret_arn" {
  description = "Secrets Manager secret holding Boundary's initial admin credentials."
  value       = module.ec2.boundary_init_secret_arn
}

output "vault_init_secret_arn" {
  description = "Secrets Manager secret holding Vault's recovery keys and initial root token."
  value       = module.ec2.vault_init_secret_arn
}

output "autoscaling_group_names" {
  description = "ASG name per node group, for the failover script and for finding instances."
  value       = module.ec2.autoscaling_group_names
}

output "iam_role_arns" {
  description = "Instance role ARN per node group. Needed later for Vault's AWS auth configuration."
  value       = module.ec2.iam_role_arns
}


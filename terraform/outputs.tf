output "hashicorp_stack_domain" {
  value = data.aws_route53_zone.public.name
}

output "ami_ids" {
  value = data.aws_ami_ids.hashicorp_stack_amis.ids
}

output "pilot_light_ami_ids" {
  value = data.aws_ami_ids.pilot_light_hashicorp_stack_amis.ids
}

output "boundary_url" {
  description = "Boundary UI and API address. Use as BOUNDARY_ADDR."
  value       = module.alb.service_urls["boundary"]
}

output "autoscaling_group_names" {
  description = "ASG name per node group, for the failover script and for finding instances."
  value       = module.ec2.autoscaling_group_names
}

output "iam_role_arns" {
  description = "Instance role ARN per node group. Needed later for Vault's AWS auth configuration."
  value       = module.ec2.iam_role_arns
}

output "boundary_init_secret_arn" {
  description = "Secrets Manager secret holding Boundary's initial admin credentials."
  value       = module.boundary_init_secret.arn
}

output "vault_init_secret_arn" {
  description = "Secrets Manager secret holding Vault's recovery keys and initial root token."
  value       = module.vault_init_secret.arn
}

output "pilot_light_autoscaling_group_names" {
  description = "ASG name per node group in the pilot-light region, for the failover script."
  value       = module.ec2_pilot_light.autoscaling_group_names
}

## App URLs
output "public_app_urls" {
  description = "Public URL per app. Served by whichever region is healthy."
  value       = { for name in keys(var.public_apps) : name => module.alb.service_urls[name] }
}
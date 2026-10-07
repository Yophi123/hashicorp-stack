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




# output "boundary_addr" {
#   value       = "http://${module.ec2.external_nlb_dns_name}:9200"
#   description = "Set BOUNDARY_ADDR to this before running `boundary authenticate`."
# }

# output "service_endpoints" {
#   value       = module.ec2.service_endpoints
#   description = "Private endpoints for Vault, Consul, Nomad and Boundary."
# }

# output "ec2_ami_ids" {
#   value       = module.ec2.ami_ids
#   description = "Ami ids of the packer images"
# }

# output "ssm_start_session_hint" {
#   value       = "aws ssm start-session --target <instance-id>"
#   description = "Break-glass path while TLS and Boundary targets are being set up."
# }

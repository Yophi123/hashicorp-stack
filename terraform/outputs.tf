output "boundary_addr" {
  value       = "http://${module.ec2.external_nlb_dns_name}:9200"
  description = "Set BOUNDARY_ADDR to this before running `boundary authenticate`."
}

output "service_endpoints" {
  value       = module.ec2.service_endpoints
  description = "Private endpoints for Vault, Consul, Nomad and Boundary."
}

output "ec2_ami_ids" {
  value       = module.ec2.ami_ids
  description = "Ami ids of the packer images"
}

output "ssm_start_session_hint" {
  value       = "aws ssm start-session --target <instance-id>"
  description = "Break-glass path while TLS and Boundary targets are being set up."
}
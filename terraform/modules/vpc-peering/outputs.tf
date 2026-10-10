output "peering_connection_id" {
  description = "ID of the VPC peering connection."
  value       = aws_vpc_peering_connection.this.id
}

output "accept_status" {
  description = "Acceptance status of the peering connection."
  value       = aws_vpc_peering_connection_accepter.peer.accept_status
}
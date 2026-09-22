output "vpc-id" {
  value       = aws_vpc.main.id
  description = "ID of the VPC"
}


output "vpc-arn" {
  value       = aws_vpc.main.arn
  description = "ARN of the VPC"
}

output "vpc-cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "IPv4 CIDR block of the VPC"
}

output "ipv6_cidr_block" {
  value       = try(aws_vpc.main.ipv6_cidr_block, null)
  description = "IPv6 CIDR block of the VPC"
}

output "public_route_table_id" {
  value       = aws_route_table.public.id
  description = "ID of the VPC's public route table"
}

output "private_route_table_id" {
  value       = aws_route_table.private.id
  description = "ID of the VPC's private route table"
}

output "web_subnet_ids" {
  value       = aws_subnet.web.*.id
  description = "List of web subnet IDs"
}

output "app_subnet_ids" {
  value       = aws_subnet.app.*.id
  description = "List of app subnet IDs"
}

output "db_subnet_ids" {
  value       = aws_subnet.db.*.id
  description = "List of database subnet IDs"
}
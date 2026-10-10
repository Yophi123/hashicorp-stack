variable "project_name" {
  type        = string
  description = "Name prefix and Project tag."
}

variable "vpc-id" {
  type        = string
  description = "VPC that requests the peering (default provider's region)."
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of the requesting VPC."
}

variable "route_table_ids" {
  type        = map(string)
  description = "Route tables in the requesting VPC that get a route to the peer. Keys are labels, values are IDs."
}

variable "peer_region" {
  type        = string
  description = "Region of the accepting VPC."
}

variable "peer_vpc-id" {
  type        = string
  description = "VPC that accepts the peering (aws.peer provider's region)."
}

variable "peer_vpc_cidr" {
  type        = string
  description = "IPv4 CIDR of the accepting VPC. Must not overlap vpc_cidr."
}

variable "peer_route_table_ids" {
  type        = map(string)
  description = "Route tables in the accepting VPC that get a route back. Keys are labels, values are IDs."
}

variable "tags" {
  type        = map(string)
  description = "Tags merged onto every resource."
  default     = {}
}
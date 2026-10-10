locals {
  tags = merge({ Project = var.project_name }, var.tags)
}

# Requested from the default provider's region.
resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.vpc-id
  peer_vpc_id = var.peer_vpc-id
  peer_region = var.peer_region

  # A cross-region request cannot accept itself; the accepter below does it.
  auto_accept = false

  tags = merge(local.tags, { Name = "${var.project_name}-peering", Side = "requester" })
}

# Accepted from the peer's region.
resource "aws_vpc_peering_connection_accepter" "peer" {
  provider = aws.peer

  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = merge(local.tags, { Name = "${var.project_name}-peering", Side = "accepter" })
}

resource "aws_route" "to_peer" {
  for_each = var.route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}

resource "aws_route" "from_peer" {
  provider = aws.peer
  for_each = var.peer_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  depends_on = [aws_vpc_peering_connection_accepter.peer]
}
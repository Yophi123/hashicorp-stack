data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"] # excludes Local/Wavelength Zones
  }
}

locals {
  az_count = 3
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
  tier_offset = {
    reserved = 0
    db       = 1
    app      = 2
    web      = 3
  }
}

## VPC 
resource "aws_vpc" "main" {
  cidr_block                       = var.vpc_cidr
  enable_dns_hostnames             = var.enable_dns_hostnames
  enable_dns_support               = var.enable_dns_support
  assign_generated_ipv6_cidr_block = var.ipv6_enabled
  tags = merge({
    "Name"    = "${var.project_name}-vpc"
    "Project" = var.project_name
  }, var.tags)
}


## Internet Gateway 
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = merge({
    "Name"    = "${var.project_name}-igw"
    "Project" = var.project_name
  }, var.tags)
}

## Egress-only Gateway(Ipv6)
resource "aws_egress_only_internet_gateway" "eigw" {
  count  = var.ipv6_enabled ? 1 : 0
  vpc_id = aws_vpc.main.id
  tags = merge({
    "Name"    = "${var.project_name}-egress-igw"
    "Project" = var.project_name
  }, var.tags)
}

## The NAT Elastic IP
resource "aws_eip" "nat-eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags = merge({
    "Name"    = "${var.project_name}-nat-eip"
    "Project" = var.project_name
  }, var.tags)
}

## Regional NAT Gateway
resource "aws_nat_gateway" "nat-gw" {
  vpc_id            = aws_vpc.main.id
  connectivity_type = "public"
  availability_mode = "regional"
  allocation_id     = aws_eip.nat-eip

  tags = merge({
    "Name"    = "${var.project_name}-natgw"
    "Project" = var.project_name
  }, var.tags)
}

## Public Route Table 
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge({
    "Name"    = "${var.project_name}-public-rt"
    "Project" = var.project_name
  }, var.tags)
}

## Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags = merge({
    "Name"    = "${var.project_name}-private-rt"
    "Project" = var.project_name
  }, var.tags)
}

## Private Routes
resource "aws_route" "private_internet_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat-gw.id
}

resource "aws_route" "private_internet_access_ipv6" {
  count                       = var.ipv6_enabled ? 1 : 0
  route_table_id              = aws_route_table.private.id
  destination_ipv6_cidr_block = "::/0"
  egress_only_gateway_id      = aws_egress_only_internet_gateway.eigw[0].id
}

## Web/Public Subnet
resource "aws_subnet" "web" {
  vpc_id            = aws_vpc.main.id
  count             = local.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index * 4 + local.tier_offset.web)
  availability_zone = local.azs[count.index]

  tags = merge({
    "Name"    = "${var.project_name}-web-${substr(local.azs[count.index], -1, 1)}"
    "Project" = var.project_name
    "Tier"    = "web"
  }, var.tags)
}

## App Subnet
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.main.id
  count             = local.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index * 4 + local.tier_offset.app)
  availability_zone = local.azs[count.index]

  tags = merge({
    "Name"    = "${var.project_name}-app-${substr(local.azs[count.index], -1, 1)}"
    "Project" = var.project_name
    "Tier"    = "app"
  }, var.tags)
}

## Database subnet
resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.main.id
  count             = local.az_count
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index * 4 + local.tier_offset.db)
  availability_zone = local.azs[count.index]

  tags = merge({
    "Name"    = "${var.project_name}-db-${substr(local.azs[count.index], -1, 1)}"
    "Project" = var.project_name
    "Tier"    = "db"
  }, var.tags)
}

## Public/Web Subnet RT Association
resource "aws_route_table_association" "web" {
  count          = local.az_count
  subnet_id      = element(aws_subnet.web.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

## App Subnet RT Association
resource "aws_route_table_association" "app" {
  count          = local.az_count
  subnet_id      = element(aws_subnet.app.*.id, count.index)
  route_table_id = aws_route_table.private.id
}

## Database RT Association 
resource "aws_route_table_association" "db" {
  count          = local.az_count
  subnet_id      = element(aws_subnet.db.*.id, count.index)
  route_table_id = aws_route_table.private
}

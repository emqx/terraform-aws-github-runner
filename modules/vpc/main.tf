data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "public" {
  for_each = { for i, name in data.aws_availability_zones.available.names: i => name }
  vpc_id = aws_vpc.vpc.id
  # "10.0.1.0/24", "10.0.2.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, each.key)
  map_public_ip_on_launch = true
  availability_zone = each.value
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_route" "igw_route" {
  route_table_id = aws_route_table.public.id
  gateway_id     = aws_internet_gateway.igw.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table_association" "public_rt_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "private" {
  for_each = { for i, name in data.aws_availability_zones.available.names: i => name }
  vpc_id = aws_vpc.vpc.id
  # "10.0.101.0/24", "10.0.102.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, 100+each.key)
  map_public_ip_on_launch = false
  availability_zone = each.value
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table_association" "private_rt_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

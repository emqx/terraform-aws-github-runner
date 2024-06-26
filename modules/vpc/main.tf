data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.vpc.id
  # "10.0.101.0/24", "10.0.102.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, 100)
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[0]
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

resource "aws_route" "igw" {
  route_table_id = aws_route_table.public.id
  gateway_id     = aws_internet_gateway.igw.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route" "igw_ipv6" {
  route_table_id = aws_route_table.public.id
  gateway_id     = aws_internet_gateway.igw.id
  destination_ipv6_cidr_block = "::/0"
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id = aws_subnet.public.id
  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_subnet" "private" {
  vpc_id = aws_vpc.vpc.id
  # "10.0.1.0/24", "10.0.2.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, 0)
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_route" "nat" {
  route_table_id = aws_route_table.private.id
  nat_gateway_id = aws_nat_gateway.nat.id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

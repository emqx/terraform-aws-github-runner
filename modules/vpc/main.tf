data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "public" {
  count = length(data.aws_availability_zones.available.names)
  vpc_id = aws_vpc.vpc.id
  # "10.0.101.0/24", "10.0.102.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, 100+count.index)
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[count.index]
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
  count = length(data.aws_availability_zones.available.names)
  subnet_id      = element(aws_subnet.public[*].id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = length(data.aws_availability_zones.available.names)
  domain = "vpc"
  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_nat_gateway" "nat" {
  count = length(data.aws_availability_zones.available.names)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id = aws_subnet.public[count.index].id
  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_subnet" "private" {
  count = length(data.aws_availability_zones.available.names)
  vpc_id = aws_vpc.vpc.id
  # "10.0.1.0/24", "10.0.2.0/24", etc.
  cidr_block = cidrsubnet(var.cidr, 8, count.index)
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[count.index]
}

resource "aws_route" "nat" {
  count = length(data.aws_availability_zones.available.names)
  route_table_id = aws_route_table.private[count.index].id
  nat_gateway_id = aws_nat_gateway.nat[count.index].id
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table" "private" {
  count = length(data.aws_availability_zones.available.names)
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route_table_association" "private" {
  count = length(data.aws_availability_zones.available.names)
  subnet_id      = element(aws_subnet.private[*].id, count.index)
  route_table_id = element(aws_route_table.private[*].id, count.index)
}

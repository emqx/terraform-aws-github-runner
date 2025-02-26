data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block                       = var.cidr
  enable_dns_hostnames             = true
  enable_dns_support               = true
  assign_generated_ipv6_cidr_block = true
  tags = {
    Name = var.prefix
  }
}

resource "aws_subnet" "public" {
  count                           = length(data.aws_availability_zones.available.names)
  vpc_id                          = aws_vpc.vpc.id
  availability_zone               = data.aws_availability_zones.available.names[count.index]
  cidr_block                      = cidrsubnet(var.cidr, 8, count.index)
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.vpc.ipv6_cidr_block, 8, count.index)
  tags = {
    Name = var.prefix
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = var.prefix
  }
}

resource "aws_route" "igw" {
  route_table_id         = aws_vpc.vpc.main_route_table_id
  gateway_id             = aws_internet_gateway.igw.id
  destination_cidr_block = "0.0.0.0/0"
  tags = {
    Name = var.prefix
  }
}

resource "aws_route" "igw_ipv6" {
  route_table_id              = aws_vpc.vpc.main_route_table_id
  gateway_id                  = aws_internet_gateway.igw.id
  destination_ipv6_cidr_block = "::/0"
  tags = {
    Name = var.prefix
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_vpc.vpc.main_route_table_id
}

locals {
  name = "${var.prefix}-docker-registry-mirror"
  log_group_name = "/github-self-hosted-runners/${local.name}/cloud-init-output"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-${var.instance_arch}-server-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_arch == "amd64" ? "t3a.small" : "t4g.small"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instance-sg.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = templatefile("${path.module}/user_data.sh", {
    log_group_name = local.log_group_name
    logging_retention_in_days = var.logging_retention_in_days
  })

  tags = {
    Name = local.name
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
}

resource "aws_iam_role" "this" {
  name = local.name
  assume_role_policy = templatefile("${path.module}/policies/instance-role-trust-policy.json", {})
}

resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name
  path = "/${local.name}/"
}

resource "aws_iam_role_policy" "ssm_session" {
  name = "${local.name}-ssm-session"
  role   = aws_iam_role.this.name
  policy = templatefile("${path.module}/policies/instance-ssm-policy.json", {})
}

resource "aws_iam_role_policy" "cloudwatch" {
  name = "${local.name}-cloudwatch"
  role  = aws_iam_role.this.name
  policy = templatefile("${path.module}/policies/instance-cloudwatch-policy.json", {})
}

resource "aws_route53_record" "dns" {
  zone_id  = var.route53_zone_id
  name     = "docker-registry-mirror.${var.route53_zone_name}"
  type     = "A"
  ttl      = 30
  records  = [aws_instance.this.private_ip]
}

resource "aws_security_group" "instance-sg" {
  vpc_id = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    protocol  = -1
    self      = true
    from_port = 0
    to_port   = 0
  }

  ingress {
    protocol  = "TCP"
    from_port = 443
    to_port   = 443
    security_groups = var.ingress_security_group_ids
  }

  ingress {
    protocol  = "TCP"
    from_port = 6379
    to_port   = 6379
    security_groups = var.ingress_security_group_ids
  }

  ingress {
    protocol  = "TCP"
    from_port = 22
    to_port   = 22
    security_groups = var.ingress_security_group_ids
  }

  tags = {
    Name = "${local.name}-security-group"
  }
}

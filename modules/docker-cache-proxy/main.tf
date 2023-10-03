locals {
  log_group_name = "/github-self-hosted-runners/${var.prefix}/cloud-init-output"
  prefix = "${var.prefix}-docker-cache-proxy"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
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
  instance_type          = "t3a.small"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = templatefile("${path.module}/user_data.sh", {
    log_group_name = local.log_group_name
  })

  tags = {
    Name = local.prefix
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
}

resource "aws_iam_role" "this" {
  name = local.prefix
  assume_role_policy = templatefile("${path.module}/policies/instance-role-trust-policy.json", {})
}

resource "aws_iam_instance_profile" "this" {
  name = local.prefix
  role = aws_iam_role.this.name
  path = "/${var.prefix}/"
}

resource "aws_iam_role_policy" "ssm_session" {
  name = "${local.prefix}-ssm-session"
  role   = aws_iam_role.this.name
  policy = templatefile("${path.module}/policies/instance-ssm-policy.json", {})
}

resource "aws_iam_role_policy" "cloudwatch" {
  name = "${var.prefix}-cloudwatch"
  role  = aws_iam_role.this.name
  policy = templatefile("${path.module}/policies/instance-cloudwatch-policy.json", {})
}

resource "aws_route53_record" "dns" {
  zone_id  = var.route53_zone_id
  name     = "${aws_instance.this.tags_all["Name"]}.${var.route53_zone_name}"
  type     = "A"
  ttl      = 30
  records  = [aws_instance.this.private_ip]
}

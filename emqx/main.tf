locals {
  environment         = "ci"
  aws_region          = "eu-west-1"
  prefix              = "ci"
  vpc_cidr            = "10.0.0.0/16"
  webhook_secret      = var.webhook_secret
  multi_runner_config = { for c in fileset("${path.module}/templates/runner-configs", "*.yaml") : trimsuffix(c, ".yaml") => yamldecode(file("${path.module}/templates/runner-configs/${c}")) }
}

resource "random_id" "random" {
  byte_length = 20
}

resource "aws_resourcegroups_group" "resourcegroups_group" {
  name = "${local.prefix}-group"
  resource_query {
    query = templatefile("${path.module}/templates/resource-group.json", {
      example = local.prefix
    })
  }
}

module "vpc" {
  source     = "../modules/vpc"
  cidr       = local.vpc_cidr
  aws_region = local.aws_region
}

module "runners" {
  source                            = "../modules/multi-runner"
  multi_runner_config               = local.multi_runner_config
  aws_region                        = local.aws_region
  vpc_id                            = module.vpc.vpc_id
  subnet_ids                        = module.vpc.public_subnet_ids
  lambda_subnet_ids                 = module.vpc.private_subnet_ids
  lambda_security_group_ids         = [aws_security_group.lambda.id]
  runners_scale_up_lambda_timeout   = 60
  runners_scale_down_lambda_timeout = 60
  runner_owner                      = "emqx"
  prefix                            = local.environment
  runners_ssm_housekeeper = {
    state  = "DISABLED"
    config = {}
  }

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = local.webhook_secret
  }

  logging_retention_in_days = 7

  webhook_lambda_zip = "../lambda_output/webhook.zip"
  runners_lambda_zip = "../lambda_output/runners.zip"
}

resource "aws_security_group" "lambda" {
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = -1
    self      = true
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${local.prefix}-lambda-security-group"
  }
}

module "webhook-github-app" {
  source = "../modules/webhook-github-app"

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = local.webhook_secret
  }
  webhook_endpoint = module.runners.webhook.endpoint
}

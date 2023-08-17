data "aws_secretsmanager_secret_version" "github_app_data" {
  secret_id = "github/app/runners/app_data"
}

data "aws_secretsmanager_secret_version" "github_app_private_key" {
  secret_id = "github/app/runners/private_key"
}

locals {
  environment = "ci"
  aws_region  = "eu-west-1"
  prefix      = "ci"
  github_app_id = jsondecode(data.aws_secretsmanager_secret_version.github_app_data.secret_string)["app_id"]
  github_app_private_key = data.aws_secretsmanager_secret_version.github_app_private_key.secret_string
}

resource "random_id" "random" {
  byte_length = 20
}

data "aws_caller_identity" "current" {}

resource "aws_resourcegroups_group" "resourcegroups_group" {
  name = "${local.prefix}-group"
  resource_query {
    query = templatefile("${path.module}/templates/resource-group.json", {
      example = local.prefix
    })
  }
}

module "vpc" {
  source = "../modules/vpc"
}

module "runners" {
  source     = "../"
  aws_region = local.aws_region
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  prefix = local.environment

  github_app = {
    key_base64     = base64encode(local.github_app_private_key)
    id             = local.github_app_id
    webhook_secret = random_id.random.hex
  }

  enable_userdata = false
  ami_filter      = { name = ["github-runner-amd64-*"], state = ["available"] }
  ami_owners      = [data.aws_caller_identity.current.account_id]
  runner_os       = "linux"
  runner_architecture = "x64"

  instance_types = ["m6a.large"]

  # disable binary syncer since github agent is already installed in the AMI.
  enable_runner_binaries_syncer = false

  # Let the module manage the service linked role
  create_service_linked_role_spot = true

  enable_ssm_on_runners = true
  enable_ephemeral_runners = true
  enable_organization_runners = true
  enable_job_queued_check = true
  enable_fifo_build_queue = true
  runner_run_as = "ubuntu"
  delay_webhook_event = 0
  minimum_running_time_in_minutes = 5
  runners_maximum_count = 256
  scale_down_schedule_expression = "cron(* * * * ? *)"
  #enable_user_data_debug_logging_runner = true
  #log_level = "debug"

  # prefix GitHub runners with the environment name
  runner_name_prefix = "${local.environment}_"

  # configure the block device mappings, default for Amazon Linux2
  block_device_mappings = [{
    device_name           = "/dev/xvda"
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = 40
    encrypted             = true
    iops                  = null
  }]

  # Grab zip files via lambda_download
  webhook_lambda_zip                = "../lambda_output/webhook.zip"
  runners_lambda_zip                = "../lambda_output/runners.zip"
  runner_binaries_syncer_lambda_zip = "../lambda_output/runner-binaries-syncer.zip"
}

resource "aws_lambda_function" "check_pending" {
  s3_bucket         = var.lambda_s3_bucket != null ? var.lambda_s3_bucket : null
  s3_key            = var.runners_lambda_s3_key != null ? var.runners_lambda_s3_key : null
  s3_object_version = var.runners_lambda_s3_object_version != null ? var.runners_lambda_s3_object_version : null
  filename          = var.lambda_s3_bucket == null ? local.lambda_zip : null
  source_code_hash  = var.lambda_s3_bucket == null ? filebase64sha256(local.lambda_zip) : null
  function_name     = "${var.prefix}-check-pending"
  role              = aws_iam_role.check_pending.arn
  handler           = "index.checkPendingHandler"
  runtime           = var.lambda_runtime
  timeout           = var.lambda_timeout_check_pending
  tags              = local.tags
  memory_size       = 512
  architectures     = [var.lambda_architecture]

  environment {
    variables = {
      ENVIRONMENT                          = var.prefix
      LOG_LEVEL                            = var.log_level
      POWERTOOLS_LOGGER_LOG_EVENT          = var.log_level == "debug" ? "true" : "false"
      RUNNER_REDIS_URL                     = var.enable_docker_registry_mirror ? module.docker-registry-mirror[0].hostname : null
      ACTION_REQUEST_MAX_WAIT_TIME         = 180
      ACTION_REQUEST_MAX_REQUEUE_COUNT     = 15
      SERVICE_NAME                         = "runners-check-pending"
      SUBNET_IDS                           = join(",", var.subnet_ids)
    }
  }

  dynamic "vpc_config" {
    for_each = var.lambda_subnet_ids != null && var.lambda_security_group_ids != null ? [true] : []
    content {
      security_group_ids = var.lambda_security_group_ids
      subnet_ids         = var.lambda_subnet_ids
    }
  }

  dynamic "tracing_config" {
    for_each = var.lambda_tracing_mode != null ? [true] : []
    content {
      mode = var.lambda_tracing_mode
    }
  }
}

resource "aws_cloudwatch_log_group" "check_pending" {
  name              = "/aws/lambda/${aws_lambda_function.check_pending.function_name}"
  retention_in_days = var.logging_retention_in_days
  kms_key_id        = var.logging_kms_key_id
  tags              = var.tags
}

resource "aws_cloudwatch_event_rule" "check_pending" {
  name                = "${var.prefix}-check-pending-rule"
  schedule_expression = var.check_pending_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "check_pending" {
  rule = aws_cloudwatch_event_rule.check_pending.name
  arn  = aws_lambda_function.check_pending.arn
}

resource "aws_lambda_permission" "check_pending" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.check_pending.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.check_pending.arn
}

resource "aws_iam_role" "check_pending" {
  name                 = "${var.prefix}-action-check-pending-lambda-role"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role_policy.json
  path                 = local.role_path
  permissions_boundary = var.role_permissions_boundary
  tags                 = local.tags
}

resource "aws_iam_role_policy" "check_pending" {
  name = "${var.prefix}-lambda-check-pending-policy"
  role = aws_iam_role.check_pending.name
  policy = templatefile("${path.module}/policies/lambda-check-pending.json", {
    github_app_id_arn         = var.github_app_parameters.id.arn
    github_app_key_base64_arn = var.github_app_parameters.key_base64.arn
    kms_key_arn               = local.kms_key_arn
  })
}

resource "aws_iam_role_policy" "check_pending_sqs" {
  name  = "${var.prefix}-lambda-check-pending-publish-sqs-policy"
  role  = aws_iam_role.check_pending.name

  policy = templatefile("${path.module}/policies/lambda-publish-sqs-policy.json", {
    sqs_resource_arns = jsonencode([var.sqs_build_queue.arn])
    kms_key_arn       = var.kms_key_arn != null ? var.kms_key_arn : ""
  })
}

resource "aws_iam_role_policy" "check_pending_logging" {
  name = "${var.prefix}-lambda-logging"
  role = aws_iam_role.check_pending.name
  policy = templatefile("${path.module}/policies/lambda-cloudwatch.json", {
    log_group_arn = aws_cloudwatch_log_group.check_pending.arn
  })
}

resource "aws_iam_role_policy" "check_pending_xray" {
  count  = var.lambda_tracing_mode != null ? 1 : 0
  policy = data.aws_iam_policy_document.lambda_xray[0].json
  role   = aws_iam_role.check_pending.name
}

resource "aws_iam_role_policy_attachment" "check_pending_vpc_execution_role" {
  count      = length(var.lambda_subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.check_pending.name
  policy_arn = "arn:${var.aws_partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

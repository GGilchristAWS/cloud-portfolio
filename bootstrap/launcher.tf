# The demo launcher: one small Lambda (launcher/handler.py) that the resume
# page calls through CloudFront (site.tf) to start the demo, and that
# EventBridge Scheduler calls a session length later to tear it down. It
# starts the repository's Deploy and Teardown workflows with a fine-grained
# GitHub token (Actions: read and write, this repository only), which the
# owner stores in the SSM parameter below:
#
#   aws ssm put-parameter --overwrite --name <launcher_token_parameter output> \
#     --type SecureString --value file://token.txt
#
# A public button costs money when pressed, so launches are capped per day
# (var.demo_daily_launches), and a press while the demo is up or starting does
# nothing. Lambda, Scheduler and SSM standard parameters are within free tiers.

locals {
  launcher_name     = "${var.project}-demo-launcher"
  teardown_schedule = "${var.project}-demo-teardown"
}

resource "aws_ssm_parameter" "launcher_github_token" {
  name        = "/${var.project}/launcher/github-token"
  description = "Fine-grained GitHub token for the demo launcher (Actions: read and write on ${var.github_owner}/${var.repo_name}). Set by the owner; Terraform only creates the parameter."
  type        = "SecureString"
  value       = "unset" # replaced by hand; never stored in state

  lifecycle {
    ignore_changes = [value]
  }

  #checkov:skip=CKV_AWS_337:The AWS managed SSM key avoids $1/month for a customer managed key
}

data "archive_file" "launcher" {
  type        = "zip"
  source_file = "${path.module}/../launcher/handler.py"
  output_path = "${path.module}/.terraform/launcher.zip"
}

resource "aws_cloudwatch_log_group" "launcher" {
  name              = "/aws/lambda/${local.launcher_name}"
  retention_in_days = 30

  #checkov:skip=CKV_AWS_158:Logs hold no secrets; a KMS key costs $1/month
  #checkov:skip=CKV_AWS_338:30 days is enough to debug a launch
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "launcher" {
  name               = local.launcher_name
  description        = "Demo launcher: reads its GitHub token and schedules the demo's teardown."
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "launcher" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.launcher.arn}:*"]
  }

  # Decryption uses the AWS managed SSM key, whose key policy already allows
  # callers in this account through SSM.
  statement {
    sid       = "GitHubToken"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.launcher_github_token.arn]
  }

  statement {
    sid       = "TeardownSchedule"
    actions   = ["scheduler:GetSchedule", "scheduler:CreateSchedule", "scheduler:UpdateSchedule"]
    resources = ["arn:aws:scheduler:${var.aws_region}:${local.account_id}:schedule/default/${local.teardown_schedule}"]
  }

  statement {
    sid       = "PassSchedulerRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.launcher_scheduler.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "launcher" {
  name   = "demo-launcher"
  role   = aws_iam_role.launcher.id
  policy = data.aws_iam_policy_document.launcher.json
}

resource "aws_lambda_function" "launcher" {
  function_name    = local.launcher_name
  description      = "Starts the on-demand demo and tears it down after a session."
  role             = aws_iam_role.launcher.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.launcher.output_path
  source_code_hash = data.archive_file.launcher.output_base64sha256
  memory_size      = 128
  timeout          = 15

  environment {
    variables = {
      GITHUB_REPO        = "${var.github_owner}/${var.repo_name}"
      DEMO_URL           = "https://${local.app_fqdn}"
      DAILY_LIMIT        = tostring(var.demo_daily_launches)
      SESSION_MINUTES    = tostring(var.demo_session_minutes)
      TOKEN_PARAMETER    = aws_ssm_parameter.launcher_github_token.name
      SCHEDULE_NAME      = local.teardown_schedule
      SCHEDULER_ROLE_ARN = aws_iam_role.launcher_scheduler.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.launcher]

  #checkov:skip=CKV_AWS_50:X-Ray adds little to two GitHub API calls
  #checkov:skip=CKV_AWS_115:Concurrency is bounded by the daily launch cap, and a reservation would take from the account's small pool
  #checkov:skip=CKV_AWS_116:Callers retry: the page reports errors and Scheduler retries a failed teardown
  #checkov:skip=CKV_AWS_117:Calls only public APIs; a VPC would need a NAT gateway
  #checkov:skip=CKV_AWS_173:The environment holds names, not secrets
  #checkov:skip=CKV_AWS_272:Code is deployed only by the bootstrap admin from git
}

# Only CloudFront may call it, signing each request (site.tf).
resource "aws_lambda_function_url" "launcher" {
  function_name      = aws_lambda_function.launcher.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "launcher_url" {
  statement_id           = "CloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.launcher.function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.site.arn
  function_url_auth_type = "AWS_IAM"
}

# Function URLs also need InvokeFunction, limited to calls made through the URL.
resource "aws_lambda_permission" "launcher_url_invoke" {
  statement_id             = "CloudFrontInvokeFunction"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.launcher.function_name
  principal                = "cloudfront.amazonaws.com"
  source_arn               = aws_cloudfront_distribution.site.arn
  invoked_via_function_url = true
}

# --- Teardown schedule -------------------------------------------------------
# The launcher creates a one-time schedule per launch, which deletes itself
# after firing. This role lets Scheduler invoke the launcher.

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "launcher_scheduler" {
  name               = "${local.launcher_name}-scheduler"
  description        = "Lets EventBridge Scheduler invoke the demo launcher to tear the demo down."
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "launcher_scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.launcher.arn]
  }
}

resource "aws_iam_role_policy" "launcher_scheduler" {
  name   = "invoke-demo-launcher"
  role   = aws_iam_role.launcher_scheduler.id
  policy = data.aws_iam_policy_document.launcher_scheduler.json
}

# Any failure, most likely an expired GitHub token, emails the owner. A failed
# teardown leaves the demo running, so this also guards the bill.
resource "aws_cloudwatch_metric_alarm" "launcher_errors" {
  alarm_name          = "${local.launcher_name}-errors"
  alarm_description   = "The demo launcher failed. Check its logs; the GitHub token may have expired."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.launcher.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

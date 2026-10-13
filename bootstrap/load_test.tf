# Shared secret for the app's /api/simulate endpoint, used by the load-test
# workflow (.github/workflows/load-test.yml). Generated once here and handed
# to both sides: the app reads it as an ECS secret from Parameter Store, and
# the workflow reads it as a secret of the production environment, which only
# main may use.

resource "random_password" "load_test_token" {
  length  = 40
  special = false
}

resource "aws_ssm_parameter" "load_test_token" {
  name        = "/${var.project}/load-test/token"
  description = "Token the load-test workflow sends to the app's /api/simulate endpoint."
  type        = "SecureString"
  value       = random_password.load_test_token.result

  #checkov:skip=CKV_AWS_337:AWS managed key (aws/ssm); a customer managed key costs $1/month
}

resource "github_actions_environment_secret" "load_test_token" {
  repository  = github_repository.this.name
  environment = github_repository_environment.production.environment
  secret_name = "LOAD_TEST_TOKEN"
  value       = random_password.load_test_token.result
}

# Attached by the app stack to the app task's execution role, which injects
# the secret (same pattern as the Grafana password in observability.tf).
data "aws_iam_policy_document" "load_test_token_read" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.load_test_token.arn]
  }
}

resource "aws_iam_policy" "load_test_token_read" {
  name        = "${var.project}-load-test-token-read"
  description = "Read the load-test token parameter (ECS task execution role)."
  policy      = data.aws_iam_policy_document.load_test_token_read.json
}

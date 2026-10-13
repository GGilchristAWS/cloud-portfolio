# Long-lived pieces of the observability stack, which itself runs in the app
# stack (infra/observability.tf) and is torn down with it each night.

# Registry for the observability config image: a tiny image holding the
# collector, Prometheus, Loki, Tempo and Grafana configs and dashboards,
# copied into a shared volume when the monitoring task starts.
resource "aws_ecr_repository" "obs_config" {
  name                 = "${var.project}-obs-config"
  image_tag_mutability = "IMMUTABLE"

  #checkov:skip=CKV_AWS_136:AES256 instead of a KMS key to avoid $1/month per key
  #checkov:skip=CKV_AWS_163:Scan on push is configured at the registry level (aws_ecr_registry_scanning_configuration)

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "obs_config" {
  repository = aws_ecr_repository.obs_config.name
  policy     = aws_ecr_lifecycle_policy.app.policy
}

# --- Grafana admin password -------------------------------------------------
# Viewers are anonymous and read-only; the admin login exists for exploring
# and drafting dashboards (which are then committed as code). The password
# lives in Parameter Store (standard parameters are free) and reaches the
# container as an ECS secret. Read it with:
#   aws ssm get-parameter --with-decryption --name /cloud-portfolio/grafana/admin-password

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name        = "/${var.project}/grafana/admin-password"
  description = "Grafana admin password for the observability stack."
  type        = "SecureString"
  value       = random_password.grafana_admin.result

  #checkov:skip=CKV_AWS_337:AWS managed key (aws/ssm); a customer managed key costs $1/month
}

# Attached by the app stack to the monitoring task's execution role, which
# injects the secret. Kept here so the deploy role can attach this policy but
# never write its own IAM policies.
data "aws_iam_policy_document" "grafana_secret_read" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.grafana_admin_password.arn]
  }
}

resource "aws_iam_policy" "grafana_secret_read" {
  name        = "${var.project}-grafana-secret-read"
  description = "Read the Grafana admin password parameter (ECS task execution role)."
  policy      = data.aws_iam_policy_document.grafana_secret_read.json
}

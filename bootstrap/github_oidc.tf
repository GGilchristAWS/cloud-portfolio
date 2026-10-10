# Keyless CI/CD: GitHub Actions exchanges a short-lived OIDC token for AWS
# credentials. No access keys are stored in GitHub.
#
#   github-actions-plan   - pull requests only; read-only AWS + state lock
#   github-actions-deploy - "production" environment only (main branch); applies changes

locals {
  repo_full_name = "${var.github_owner}/${var.repo_name}"
  oidc_host      = "token.actions.githubusercontent.com"

  # The application stack keeps its state under this prefix. CI roles cannot
  # touch the bootstrap stack's state.
  app_state_prefix = "app/"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan   = "repo:${local.repo_full_name}:pull_request"
    deploy = "repo:${local.repo_full_name}:environment:production"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# --- Plan role -------------------------------------------------------------

resource "aws_iam_role" "github_plan" {
  name               = "github-actions-plan"
  description        = "Assumed by GitHub Actions on pull requests to run terraform plan."
  assume_role_policy = data.aws_iam_policy_document.github_trust["plan"].json
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_plan_state" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.app_state_prefix}*"]
    }
  }

  statement {
    sid       = "ReadAppState"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/${local.app_state_prefix}*"]
  }

  statement {
    sid       = "ManageLockFile"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/${local.app_state_prefix}*.tflock"]
  }
}

resource "aws_iam_role_policy" "github_plan_state" {
  name   = "terraform-state-read-lock"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan_state.json
}

# --- Deploy role -----------------------------------------------------------
# Service permissions for the application stack are added in Phase 5, once
# the hosting architecture is chosen. Until then it can only manage state.

resource "aws_iam_role" "github_deploy" {
  name               = "github-actions-deploy"
  description        = "Assumed by GitHub Actions in the production environment to apply changes."
  assume_role_policy = data.aws_iam_policy_document.github_trust["deploy"].json
}

data "aws_iam_policy_document" "github_deploy_state" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.app_state_prefix}*"]
    }
  }

  statement {
    sid       = "ReadWriteAppState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/${local.app_state_prefix}*"]
  }
}

resource "aws_iam_role_policy" "github_deploy_state" {
  name   = "terraform-state-read-write"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_state.json
}

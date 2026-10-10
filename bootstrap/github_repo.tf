# The repository itself is managed as code, including the ruleset that makes
# main reachable only through pull requests that pass CI.

locals {
  # Must match the job names in .github/workflows/ci.yml.
  required_checks = [
    "App: lint & test",
    "Image: build & scan",
    "IaC: fmt, lint, validate, scan",
    "Terraform plan",
  ]
  github_actions_app_id = 15368
}

resource "github_repository" "this" {
  name        = var.repo_name
  description = "Cloud operations portfolio: containerized app on AWS, Terraform IaC, GitHub Actions CI/CD with OIDC."
  visibility  = "public" #checkov:skip=CKV_GIT_1:Public by design: this is a portfolio
  topics      = ["aws", "terraform", "github-actions", "devops", "cloud-engineering", "containers"]

  has_issues   = true
  has_projects = false
  has_wiki     = false

  allow_merge_commit     = false
  allow_rebase_merge     = false
  allow_squash_merge     = true
  delete_branch_on_merge = true

  archive_on_destroy = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

# No bypass actors: the admin goes through pull requests too. Approvals are not
# required because GitHub does not let a sole maintainer approve their own PR.
resource "github_repository_ruleset" "main" {
  name        = "protect-main"
  repository  = github_repository.this.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = true
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      dynamic "required_check" {
        for_each = local.required_checks

        content {
          context        = required_check.value
          integration_id = local.github_actions_app_id
        }
      }
    }
  }
}

resource "github_repository_vulnerability_alerts" "this" {
  repository = github_repository.this.name
  enabled    = true
}

resource "github_repository_environment" "production" {
  repository  = github_repository.this.name
  environment = "production"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "production_main" {
  repository     = github_repository.this.name
  environment    = github_repository_environment.production.environment
  branch_pattern = "main"
}

# Role ARNs and bucket names are identifiers, not secrets, so they are stored
# as Actions variables.

resource "github_actions_variable" "repo" {
  for_each = {
    AWS_REGION        = var.aws_region
    AWS_PLAN_ROLE_ARN = aws_iam_role.github_plan.arn
    TF_STATE_BUCKET   = aws_s3_bucket.tfstate.bucket
    ECR_REPOSITORY    = aws_ecr_repository.app.name
  }

  repository    = github_repository.this.name
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_variable" "deploy_role" {
  repository    = github_repository.this.name
  environment   = github_repository_environment.production.environment
  variable_name = "AWS_DEPLOY_ROLE_ARN"
  value         = aws_iam_role.github_deploy.arn
}

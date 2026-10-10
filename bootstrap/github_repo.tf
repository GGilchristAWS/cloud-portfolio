# The repository itself is managed as code. Branch rulesets are added once the
# CI workflows exist, so they can require those status checks.

resource "github_repository" "this" {
  name        = var.repo_name
  description = "Cloud operations portfolio: containerized app on AWS, Terraform IaC, GitHub Actions CI/CD with OIDC."
  visibility  = "public"
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

# The GitHub repository and its settings were first managed by this stack in
# the management account. These blocks adopt them into the state in the
# portfolio account; remove them after the first apply.
#
# Before applying, release them from the old state (management account):
#   terraform state rm <each address below>
# Vulnerability alerts are not imported: enabling them is idempotent.

import {
  to = github_repository.this
  id = var.repo_name
}

import {
  to = github_repository_ruleset.main
  id = "${var.repo_name}:24851686"
}

import {
  to = github_repository_environment.production
  id = "${var.repo_name}:production"
}

import {
  to = github_repository_environment_deployment_policy.production_main
  id = "${var.repo_name}:production:62617663"
}

import {
  for_each = toset(["AWS_REGION", "AWS_PLAN_ROLE_ARN", "TF_STATE_BUCKET", "ECR_REPOSITORY"])

  to = github_actions_variable.repo[each.key]
  id = "${var.repo_name}:${each.key}"
}

import {
  to = github_actions_environment_variable.deploy_role
  id = "${var.repo_name}:production:AWS_DEPLOY_ROLE_ARN"
}

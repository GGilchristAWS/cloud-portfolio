output "state_bucket" {
  description = "S3 bucket holding Terraform state for all stacks."
  value       = aws_s3_bucket.tfstate.bucket
}

output "plan_role_arn" {
  description = "IAM role assumed by GitHub Actions on pull requests."
  value       = aws_iam_role.github_plan.arn
}

output "deploy_role_arn" {
  description = "IAM role assumed by GitHub Actions in the production environment."
  value       = aws_iam_role.github_deploy.arn
}

output "ecr_repository_url" {
  description = "ECR repository for the app image."
  value       = aws_ecr_repository.app.repository_url
}

output "alerts_topic_arn" {
  description = "SNS topic for app stack alarms."
  value       = aws_sns_topic.alerts.arn
}

output "assistant_readonly_role_arn" {
  description = "Read-only role for AI assistants and tooling (used by a CLI profile)."
  value       = aws_iam_role.assistant_readonly.arn
}

output "repository_url" {
  description = "GitHub repository URL."
  value       = github_repository.this.html_url
}

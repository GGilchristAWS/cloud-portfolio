variable "project" {
  description = "Project name, used for resource naming and tags."
  type        = string
  default     = "cloud-portfolio"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository."
  type        = string
  default     = "GGilchristAWS"
}

variable "repo_name" {
  description = "GitHub repository name."
  type        = string
  default     = "cloud-portfolio"
}

variable "budget_alert_email" {
  description = "Email address that receives AWS Budgets alerts. Set in terraform.tfvars (gitignored)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget in USD (gross usage, before credits)."
  type        = number
  default     = 10
}

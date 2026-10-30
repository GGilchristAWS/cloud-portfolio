variable "project" {
  description = "Project name, used for resource naming and tags."
  type        = string
  default     = "cloud-portfolio"
}

variable "domain_name" {
  description = "Route 53 zone the app is served from, delegated from geoffgilchrist.com (aws-org repo)."
  type        = string
  default     = "portfolio.geoffgilchrist.com"
}

variable "app_subdomain" {
  description = "Subdomain the on-demand demo is served on. The apex is the static resume (site.tf). Must match the app stack."
  type        = string
  default     = "demo"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-west-2"
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
  description = "Monthly cost budget in USD (actual bill)."
  type        = number
  default     = 10
}

variable "daily_budget_usd" {
  description = "Daily cost budget in USD. Exceeding it usually means a demo stack was left running."
  type        = number
  default     = 1.5
}

variable "anomaly_threshold_usd" {
  description = "Minimum total impact in USD for a cost anomaly alert."
  type        = number
  default     = 3
}

variable "demo_daily_launches" {
  description = "Launches of the on-demand demo allowed per day (UTC), from the resume page or by hand."
  type        = number
  default     = 4
}

variable "demo_session_minutes" {
  description = "Minutes from a launch until the demo is torn down. A deploy takes about 10 of them."
  type        = number
  default     = 120
}

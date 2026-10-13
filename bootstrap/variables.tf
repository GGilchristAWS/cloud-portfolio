variable "project" {
  description = "Project name, used for resource naming and tags."
  type        = string
  default     = "cloud-portfolio"
}

variable "domain_name" {
  description = "Registered domain (registrar: Namecheap) whose DNS is hosted in Route 53."
  type        = string
  default     = "mirkwood.xyz"
}

variable "app_subdomain" {
  description = "Subdomain the app is served on. Must match the app stack."
  type        = string
  default     = "portfolio"
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

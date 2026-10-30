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

variable "waf_enabled" {
  description = "Put the WAF web ACL (per-IP rate limit, AWS IP reputation list) in front of all three distributions. About $7/month while on; turn on when abuse is seen (edge.tf)."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per IP per 5 minutes before WAF blocks it. 2000 is about 7 a second, far above a person browsing the dashboards."
  type        = number
  default     = 2000
}

variable "edge_requests_alarm" {
  description = "Requests in 15 minutes, across the resume, demo and Grafana, that set off the traffic alarm (edge.tf). The burst load test peaks near 36,000."
  type        = number
  default     = 100000
}

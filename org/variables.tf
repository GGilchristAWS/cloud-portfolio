variable "project" {
  description = "Project name, used for resource naming and tags."
  type        = string
  default     = "cloud-portfolio"
}

variable "aws_region" {
  description = "Home region of Organizations and IAM Identity Center."
  type        = string
  default     = "us-east-1"
}

variable "repo" {
  description = "Repository that manages this stack, for tagging."
  type        = string
  default     = "GGilchristAWS/cloud-portfolio"
}

variable "portfolio_account_email" {
  description = "Root user email of the portfolio workload account. Set in terraform.tfvars (gitignored)."
  type        = string

  # An account created with an address you don't control can't recover its root user.
  validation {
    condition     = !endswith(lower(var.portfolio_account_email), "@example.com")
    error_message = "portfolio_account_email is still the example placeholder."
  }
}

variable "identity_center_user_name" {
  description = "IAM Identity Center user granted access to the portfolio account. Set in terraform.tfvars (gitignored)."
  type        = string
}

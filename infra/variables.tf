variable "project" {
  description = "Project name, used for resource naming and tags. Must match the bootstrap stack."
  type        = string
  default     = "cloud-portfolio"
}

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-west-2"
}

variable "domain_name" {
  description = "Route 53 zone the app is served from, delegated from geoffgilchrist.com (aws-org repo)."
  type        = string
  default     = "portfolio.geoffgilchrist.com"
}

variable "app_subdomain" {
  description = "Subdomain the app is served on; empty serves it at the zone apex. Must match the bootstrap stack."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Tag of the image in ECR to deploy (the git commit SHA)."
  type        = string

  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "container_port" {
  description = "Port the app listens on inside the container."
  type        = number
  default     = 8000
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU, the smallest size)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of running tasks."
  type        = number
  default     = 1
}

variable "use_spot" {
  description = "Run tasks on Fargate Spot (up to ~70% cheaper, may be interrupted)."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for app logs."
  type        = number
  default     = 7
}

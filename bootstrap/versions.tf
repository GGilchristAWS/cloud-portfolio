terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "bootstrap"
      ManagedBy = "terraform"
      Repo      = "${var.github_owner}/${var.repo_name}"
    }
  }
}

# Authenticates with the GITHUB_TOKEN environment variable (e.g. from `gh auth token`).
provider "github" {
  owner = var.github_owner
}

data "aws_caller_identity" "current" {}

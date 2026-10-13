terraform {
  required_version = ">= 1.10" # S3 native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Runs in the organization's management account. Organizations and IAM
# Identity Center are both homed in us-east-1.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "org"
      ManagedBy = "terraform"
      Repo      = var.repo
    }
  }
}

data "aws_organizations_organization" "this" {}

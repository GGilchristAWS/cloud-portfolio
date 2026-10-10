terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # CI roles are scoped to the app/ prefix of the state bucket.
  backend "s3" {
    bucket       = "cloud-portfolio-tfstate-014574285066"
    key          = "app/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      Stack     = "app"
      ManagedBy = "terraform"
      Repo      = "GGilchristAWS/cloud-portfolio"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  #checkov:skip=CKV_AWS_394:Only the first two zones are used; new zones sort after them
}

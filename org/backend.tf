# State lives in the management account's state bucket, beside the bootstrap
# stack's original state.
terraform {
  backend "s3" {
    bucket       = "cloud-portfolio-tfstate-014574285066"
    key          = "org/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

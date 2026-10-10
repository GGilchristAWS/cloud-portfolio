# The bucket is created by this stack. It was first applied with local state,
# then migrated here with `terraform init -migrate-state`.
terraform {
  backend "s3" {
    bucket       = "cloud-portfolio-tfstate-014574285066"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

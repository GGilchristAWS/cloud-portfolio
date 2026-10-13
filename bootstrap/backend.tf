# The bucket is created by this stack. On a fresh account the first apply runs
# with local state (a gitignored backend_override.tf), then the state is moved
# here with `terraform init -migrate-state`.
terraform {
  backend "s3" {
    bucket       = "cloud-portfolio-tfstate-010443043480"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

# The image registry lives here rather than in the app stack so images survive
# the nightly teardown. Storage for a handful of ~200 MB images costs cents.

resource "aws_ecr_repository" "app" {
  name                 = var.project
  image_tag_mutability = "IMMUTABLE"

  #checkov:skip=CKV_AWS_136:AES256 instead of a KMS key to avoid $1/month per key
  #checkov:skip=CKV_AWS_163:Scan on push is configured at the registry level (aws_ecr_registry_scanning_configuration)

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Basic scanning (no charge) on every push, configured at the registry level.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"

    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

# Images must be pushed as single manifests (docker build --provenance=false
# --sbom=false). BuildKit's default attestations wrap the image in an index
# whose child manifests are untagged: basic scanning skips the index, and the
# untagged-expiry rule below would delete the children out from under it.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 10 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}

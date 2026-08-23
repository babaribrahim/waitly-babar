provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner       = var.owner
      Environment = var.environment
      Project     = var.project
    }
  }
}

# NOTE: the CloudFront/ACM phase (frontend) will need a second, aliased
# provider block scoped to us-east-1 — deliberately not added here. This
# module has no resource that needs it, and CLAUDE.md is explicit that
# nothing outside that one ACM certificate should ever reference it.

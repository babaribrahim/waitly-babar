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

# The one exception to the Oregon-only rule: CloudFront requires its ACM
# certificate to be issued in us-east-1 regardless of which region the
# rest of the stack lives in - not a choice, a hard CloudFront platform
# requirement. Nothing else in this project should ever reference this
# provider (see cloudfront.tf's aws_acm_certificate resource - the only
# thing that does).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Owner       = var.owner
      Environment = var.environment
      Project     = var.project
    }
  }
}

terraform {
  required_version = ">= 1.11.0" # 1.11+ needed by infra/live for S3 native state locking (use_lockfile)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Deliberately local state for this module only: it creates the bucket
  # that every other module's state will live in, so it can't depend on
  # that bucket existing yet. This is the one piece of state that stays
  # on-disk; treat infra/bootstrap/terraform.tfstate as precious.
}

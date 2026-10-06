terraform {
  # 1.10+ for native S3 state locking (use_lockfile) in backend.tf.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

# Bootstrap: the pieces that must exist before CI can run Terraform.
#
#   main.tf     -> KMS key + S3 state bucket (native S3 locking, no DynamoDB)
#   ci_roles.tf -> GitHub OIDC provider + plan / apply / ami-builder roles
#   budget.tf   -> monthly cost budget with an email alert
#
# Applied ONCE, locally, with admin credentials. Its own state stays local
# (terraform.tfstate here, gitignored): it creates the bucket remote state would
# live in. Back the file up, or migrate it into the bucket afterwards with a
# backend block and `terraform init -migrate-state`.
#
# This stack stays up between sessions (it costs cents). envs/lab is destroyed.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# State encryption key
# ---------------------------------------------------------------------------

resource "aws_kms_key" "state" {
  description             = "${var.project}: Terraform state bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = local.tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.project}-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0089 Server access logging for a single-user state bucket needs a second bucket; CloudTrail covers API access.
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  tags = local.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every state version is kept, so a bad apply can be recovered from.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Default SSE-KMS applies to state and lock objects alike, so the backend
# doesn't need encrypt/kms_key_id. Bucket keys cut KMS request costs.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 10
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

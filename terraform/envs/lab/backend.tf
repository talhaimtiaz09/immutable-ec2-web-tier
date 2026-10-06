# Remote state in the S3 bucket created by terraform/bootstrap, with native S3
# locking: Terraform writes a "<key>.tflock" object next to the state, so no
# DynamoDB table is needed (Terraform >= 1.10). The plan role can write and
# delete that lock object too, since plan takes the lock.
#
# Encryption comes from the bucket's default SSE-KMS. `encrypt = true` is left
# out on purpose: without a kms_key_id it would request SSE-S3 instead.
#
# The bucket name is account-specific, so it is passed at init time:
#
#   terraform init -backend-config="bucket=<state_bucket output from bootstrap>"
#
# For credential-free fmt/validate work: terraform init -backend=false
terraform {
  backend "s3" {
    key          = "immutable-ec2-web-tier/lab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

output "state_bucket" {
  description = "State bucket name: pass as -backend-config=\"bucket=...\" and set as the TF_STATE_BUCKET repository variable."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state bucket."
  value       = aws_kms_key.state.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN (created or looked up)."
  value       = local.github_oidc_provider_arn
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN repository variable."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the AWS_APPLY_ROLE_ARN repository (or lab environment) variable."
  value       = aws_iam_role.apply.arn
}

output "ami_builder_role_arn" {
  description = "Set as the AWS_AMI_BUILDER_ROLE_ARN repository variable (ami.yml)."
  value       = aws_iam_role.ami_builder.arn
}

output "packer_instance_profile_name" {
  description = "Instance profile for Packer's temporary build instance (iam_instance_profile in the Packer template)."
  value       = aws_iam_instance_profile.packer_instance.name
}

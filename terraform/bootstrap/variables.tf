variable "region" {
  description = "AWS region for the state bucket and the regions the CI roles may act in."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name. Used for naming, tagging and the state key prefix."
  type        = string
  default     = "immutable-ec2-web-tier"
}

variable "environment" {
  description = "Workload environment the apply role manages. Its IAM/SNS/SSM/S3 permissions are scoped to \"<project>-<environment>-*\" names."
  type        = string
  default     = "lab"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "talhaimtiaz09"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may assume the CI roles."
  type        = string
  default     = "talhaimtiaz09/immutable-ec2-web-tier"
}

variable "github_environment" {
  description = "GitHub Environment the apply job runs in. It changes the OIDC sub claim to repo:<repo>:environment:<name>."
  type        = string
  default     = "lab"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. An account has at most one per URL; set false if it already exists (e.g. from eks-paved-road) and it is looked up instead. Check with: aws iam list-open-id-connect-providers"
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "State bucket name. Defaults to \"<project>-tfstate-<account id>\" (globally unique)."
  type        = string
  default     = null
}

variable "budget_limit_usd" {
  description = "Monthly cost budget for the account, in USD."
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Email notified at 80% of actual spend and 100% of forecast spend."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be an email address."
  }
}

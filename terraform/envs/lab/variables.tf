variable "region" {
  description = "AWS region for all resources. Keep in sync with the backend region in backend.tf."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name. Used for naming and tagging."
  type        = string
  default     = "immutable-ec2-web-tier"
}

variable "environment" {
  description = "Environment name. The bootstrap apply role is scoped to IAM names starting with \"<project>-<environment>-\"."
  type        = string
  default     = "lab"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
  default     = "talhaimtiaz09"
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "ami_id" {
  description = "Golden AMI ID built by Packer. Lives in lab.tfvars so every rollout is a reviewed diff and rollback is a git revert."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "App instance type (arm64)."
  type        = string
  default     = "t4g.small"
}

variable "asg_min_size" {
  description = "ASG minimum size."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "ASG maximum size."
  type        = number
  default     = 4
}

variable "instance_warmup" {
  description = "Seconds from launch until an instance serves traffic. Measure it and update."
  type        = number
  default     = 120
}

variable "deregistration_delay" {
  description = "ALB drain time in seconds. Must exceed the app's graceful-shutdown timeout."
  type        = number
  default     = 30
}

variable "db_engine_version" {
  description = "Postgres engine version."
  type        = string
  default     = "16"
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention in days (PITR window)."
  type        = number
  default     = 1
}

variable "alarm_email" {
  description = "Email address for alarm notifications. CI sets it from the ALARM_EMAIL repository variable (TF_VAR_alarm_email)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be an email address."
  }
}

variable "domain_name" {
  description = "Optional FQDN for HTTPS (e.g. lab.talhaimtiaz.me). Null keeps the ALB HTTP-only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Route 53 public zone for domain_name. Defaults to domain_name (a delegated subdomain zone)."
  type        = string
  default     = null
}

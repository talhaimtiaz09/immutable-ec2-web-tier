variable "name" {
  description = "Name prefix and DB instance identifier."
  type        = string
}

variable "vpc_id" {
  description = "VPC the DB security group is created in."
  type        = string
}

variable "subnet_ids" {
  description = "DB subnet IDs for the subnet group (at least two AZs)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "An RDS subnet group needs subnets in at least two AZs."
  }
}

variable "allowed_security_group_id" {
  description = "Security group allowed to reach Postgres on 5432 (the app tier)."
  type        = string
}

variable "engine_version" {
  description = "Postgres engine version. A major version picks the current default minor."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial database the app uses."
  type        = string
  default     = "app"
}

variable "master_username" {
  description = "Master username. The password is generated and managed by RDS."
  type        = string
  default     = "app_admin"
}

variable "backup_retention_days" {
  description = "Automated backup retention in days. Must be >= 1 for point-in-time restore."
  type        = number
  default     = 1

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35 (0 disables PITR)."
  }
}

variable "tags" {
  description = "Tags applied to all RDS resources."
  type        = map(string)
  default     = {}
}

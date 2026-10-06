variable "name" {
  description = "Name prefix for every resource. Keep it <= 26 characters (ALB and target group names cap at 32)."
  type        = string

  validation {
    condition     = length(var.name) <= 26
    error_message = "name must be 26 characters or fewer so \"<name>-alb\" fits the 32-character ALB limit."
  }
}

# --- Network -----------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the ALB (two AZs minimum)."
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private app subnet IDs for the ASG."
  type        = list(string)
}

# --- Instances ---------------------------------------------------------------

variable "ami_id" {
  description = "Golden AMI ID (arm64, owned by this account). Changing it starts an instance refresh."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-0123456789abcdef0."
  }
}

variable "instance_type" {
  description = "Instance type. Must be arm64 (Graviton) to match the golden AMI."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size" {
  description = "Root volume size in GiB. Must be at least the AMI's snapshot size."
  type        = number
  default     = 10
}

variable "app_port" {
  description = "Port the app listens on."
  type        = number
  default     = 8080
}

variable "app_service_name" {
  description = "systemd unit name of the app baked into the AMI."
  type        = string
  default     = "app"
}

variable "app_log_path" {
  description = "App log file the CloudWatch agent ships. Must match what the AMI's app writes."
  type        = string
  default     = "/var/log/app/app.log"
}

variable "log_retention_days" {
  description = "Retention for the app CloudWatch log group."
  type        = number
  default     = 14
}

# --- Scaling and rollout -----------------------------------------------------

variable "min_size" {
  description = "ASG minimum size."
  type        = number
  default     = 2
}

variable "max_size" {
  description = "ASG maximum size."
  type        = number
  default     = 4
}

variable "instance_warmup" {
  description = "Seconds from launch until an instance is serving (measure the real boot time). Used for refresh warmup, scaling warmup and the health check grace period."
  type        = number
  default     = 120
}

variable "target_requests_per_instance" {
  description = "Target tracking value for ALBRequestCountPerTarget (requests per target per minute)."
  type        = number
  default     = 300
}

# --- Load balancer -----------------------------------------------------------

variable "health_check_path" {
  description = "Shallow liveness path used by the target group. Must not check the DB."
  type        = string
  default     = "/healthz"
}

variable "deregistration_delay" {
  description = "Seconds the ALB drains a target before the ASG terminates it. Set just above the app's SIGTERM drain timeout."
  type        = number
  default     = 30
}

variable "access_log_retention_days" {
  description = "Days to keep ALB access logs in S3."
  type        = number
  default     = 7
}

variable "domain_name" {
  description = "Optional FQDN (e.g. lab.example.com). When set: ACM cert with DNS validation, HTTPS listener, HTTP->HTTPS redirect and an alias record. Null means HTTP only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Public Route 53 zone holding domain_name. Defaults to domain_name itself (a delegated subdomain zone)."
  type        = string
  default     = null
}

# --- Database wiring (from modules/rds) --------------------------------------

variable "db_endpoint" {
  description = "DB hostname passed to instances via user data."
  type        = string
}

variable "db_port" {
  description = "DB port. Also the app SG's only non-HTTPS egress port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Database name passed to instances."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the RDS-managed master secret. The instance role may read this secret only."
  type        = string
}

variable "db_secret_kms_key_arn" {
  description = "ARN of the KMS key encrypting the master secret. The instance role may decrypt with it via Secrets Manager only."
  type        = string
}

variable "db_security_group_id" {
  description = "DB security group ID; the app SG egresses to it on db_port."
  type        = string
}

variable "db_instance_identifier" {
  description = "RDS instance identifier, for the dashboard's DB widget."
  type        = string
}

# --- Alerting ----------------------------------------------------------------

variable "alarm_email" {
  description = "Email address subscribed to the alerts SNS topic (confirm the subscription email)."
  type        = string
}

variable "target_5xx_threshold" {
  description = "Target 5xx count per minute that raises the alarm and rolls back an in-progress instance refresh."
  type        = number
  default     = 5
}

variable "p95_latency_threshold_seconds" {
  description = "p95 TargetResponseTime threshold in seconds."
  type        = number
  default     = 0.5
}

variable "tags" {
  description = "Tags applied to all resources (and to instances and volumes through the launch template)."
  type        = map(string)
  default     = {}
}

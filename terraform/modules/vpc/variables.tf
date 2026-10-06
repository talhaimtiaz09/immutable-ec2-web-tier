variable "name" {
  description = "Name prefix for the VPC and its resources."
  type        = string
}

variable "cidr" {
  description = "Primary IPv4 CIDR block for the VPC. Must be /16 or larger so each tier gets /24s."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread each subnet tier across. The ALB and RDS subnet group both need at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 10
    error_message = "az_count must be between 2 and 10."
  }
}

variable "nat_instance_type" {
  description = "Instance type for the fck-nat instance. Must be arm64 (Graviton) to match the AMI lookup."
  type        = string
  default     = "t4g.nano"
}

variable "tags" {
  description = "Tags applied to all VPC resources."
  type        = map(string)
  default     = {}
}

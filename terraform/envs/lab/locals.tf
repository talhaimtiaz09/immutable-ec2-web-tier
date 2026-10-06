locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Owner       = var.owner
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

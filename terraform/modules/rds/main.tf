# Private Postgres for the app tier.
#
# - Single-AZ db.t4g.micro in the isolated DB subnets; not publicly accessible.
# - Storage AND the master secret are encrypted with one customer-managed KMS
#   key, so the instance role's kms:Decrypt can be scoped to exactly this key.
# - manage_master_user_password: RDS generates the password, stores it in
#   Secrets Manager and rotates it. No password ever exists in Terraform
#   variables, tfvars or state.
# - Postgres 15+ defaults rds.force_ssl=1, so TLS is enforced without a custom
#   parameter group.

resource "aws_kms_key" "this" {
  description             = "${var.name}: RDS storage and master user secret"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.this.key_id
}

resource "aws_db_subnet_group" "this" {
  name        = var.name
  description = "${var.name}: isolated DB subnets"
  subnet_ids  = var.subnet_ids

  tags = var.tags
}

# Ingress on the DB port from the app tier's security group only.
# No egress rules: Terraform removes the AWS default allow-all egress.
resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "${var.name}: Postgres, reachable only from the app tier SG."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

# A single input SG id rather than a list: the app SG is created in the same
# apply, and for_each over not-yet-known IDs fails at plan time.
resource "aws_vpc_security_group_ingress_rule" "from_app" {
  security_group_id            = aws_security_group.this.id
  description                  = "Postgres from the app tier SG"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = var.allowed_security_group_id
}

#trivy:ignore:AWS-0133 Performance Insights is not needed for a lab instance; CloudWatch metrics cover the drills.
#trivy:ignore:AWS-0176 The app authenticates with the RDS-managed secret, not IAM database auth.
#trivy:ignore:AWS-0177 Lab is destroyed every session; deletion protection would block terraform destroy.
#trivy:ignore:AWS-0077 Lab: a 1-day PITR window is enough for the restore drill; production keeps 7-35 days.
resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.master_username
  port     = 5432

  # Password generated, stored and rotated by RDS in Secrets Manager.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.this.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false # lab: single-AZ. Production would be Multi-AZ.

  # Short retention is enough for the point-in-time restore drill.
  backup_retention_period  = var.backup_retention_days
  backup_window            = "03:00-03:30"
  maintenance_window       = "sun:04:00-sun:04:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Lab only: destroyed at the end of every session, no final snapshot kept.
  skip_final_snapshot = true
  deletion_protection = false

  tags = var.tags
}

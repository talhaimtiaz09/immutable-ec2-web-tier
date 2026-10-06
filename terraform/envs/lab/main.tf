# lab environment root: wires the modules together:
#   vpc     -> 3 tiers x 2 AZs, fck-nat, S3 gateway endpoint
#   rds     -> private Postgres, CMK, RDS-managed master secret
#   alb-asg -> ALB, launch template, ASG with alarm-gated instance refresh,
#              instance role, alarms, SNS topic, dashboard
#   RDS alarms (CPU, free storage) on the alb-asg alerts topic
#
# The app SG (alb-asg) and DB SG (rds) reference each other. Terraform resolves
# that per resource, so there is no module cycle.
#
# Destroy at the end of every session: terraform destroy -var-file=lab.tfvars

module "vpc" {
  source = "../../modules/vpc"

  name = local.name
  cidr = var.vpc_cidr
  tags = local.tags
}

module "rds" {
  source = "../../modules/rds"

  name                      = local.name
  vpc_id                    = module.vpc.vpc_id
  subnet_ids                = module.vpc.db_subnet_ids
  allowed_security_group_id = module.alb_asg.app_security_group_id

  engine_version        = var.db_engine_version
  backup_retention_days = var.db_backup_retention_days

  tags = local.tags
}

module "alb_asg" {
  source = "../../modules/alb-asg"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  app_subnet_ids    = module.vpc.app_subnet_ids

  ami_id        = var.ami_id
  instance_type = var.instance_type
  min_size      = var.asg_min_size
  max_size      = var.asg_max_size

  instance_warmup      = var.instance_warmup
  deregistration_delay = var.deregistration_delay

  db_endpoint            = module.rds.endpoint
  db_port                = module.rds.port
  db_name                = module.rds.db_name
  db_secret_arn          = module.rds.master_user_secret_arn
  db_secret_kms_key_arn  = module.rds.kms_key_arn
  db_security_group_id   = module.rds.security_group_id
  db_instance_identifier = module.rds.db_instance_identifier

  alarm_email      = var.alarm_email
  domain_name      = var.domain_name
  hosted_zone_name = var.hosted_zone_name

  tags = local.tags
}

# ---------------------------------------------------------------------------
# RDS alarms -> the same SNS topic as the web tier alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu"
  alarm_description   = "RDS CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "missing"

  alarm_actions = [module.alb_asg.alerts_topic_arn]
  ok_actions    = [module.alb_asg.alerts_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${local.name}-rds-free-storage"
  alarm_description   = "RDS free storage below 2 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = module.rds.db_instance_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024 # bytes
  treat_missing_data  = "missing"

  alarm_actions = [module.alb_asg.alerts_topic_arn]
  ok_actions    = [module.alb_asg.alerts_topic_arn]
}

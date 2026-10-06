output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = module.alb_asg.alb_dns_name
}

output "app_url" {
  description = "Base URL of the app (try /healthz and /version)."
  value       = module.alb_asg.app_url
}

output "asg_name" {
  description = "Auto Scaling group name (aws autoscaling describe-instance-refreshes --auto-scaling-group-name ...)."
  value       = module.alb_asg.asg_name
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${module.alb_asg.dashboard_name}"
}

output "db_endpoint" {
  description = "RDS hostname (private)."
  value       = module.rds.endpoint
}

output "db_secret_arn" {
  description = "ARN of the RDS-managed master secret."
  value       = module.rds.master_user_secret_arn
}

output "alerts_topic_arn" {
  description = "SNS topic for alarms. Confirm the email subscription after the first apply."
  value       = module.alb_asg.alerts_topic_arn
}

output "region" {
  description = "AWS region."
  value       = var.region
}

# Read by scripts/rollout.sh after each apply.
output "launch_template_id" {
  description = "Launch template ID."
  value       = module.alb_asg.launch_template_id
}

output "launch_template_latest_version" {
  description = "Newest launch template version (the rollout target)."
  value       = module.alb_asg.launch_template_latest_version
}

output "rollback_alarm_names" {
  description = "Alarms that roll back an in-progress instance refresh."
  value       = module.alb_asg.rollback_alarm_names
}

output "instance_warmup" {
  description = "Instance warmup in seconds."
  value       = module.alb_asg.instance_warmup
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch LoadBalancer dimension)."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (CloudWatch TargetGroup dimension)."
  value       = aws_lb_target_group.app.arn_suffix
}

output "app_url" {
  description = "Base URL of the app: https://<domain_name> when set, otherwise http://<alb dns name>."
  value       = var.domain_name != null ? "https://${var.domain_name}" : "http://${aws_lb.this.dns_name}"
}

output "asg_name" {
  description = "Auto Scaling group name."
  value       = aws_autoscaling_group.app.name
}

output "launch_template_id" {
  description = "Launch template ID."
  value       = aws_launch_template.app.id
}

output "launch_template_latest_version" {
  description = "Newest launch template version. scripts/rollout.sh refreshes the ASG to it."
  value       = aws_launch_template.app.latest_version
}

output "app_security_group_id" {
  description = "App tier security group ID (the DB SG allows Postgres from it)."
  value       = aws_security_group.app.id
}

output "alb_security_group_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "instance_role_name" {
  description = "Name of the app instance IAM role."
  value       = aws_iam_role.app.name
}

output "alerts_topic_arn" {
  description = "SNS topic ARN for alarm notifications (reuse it for other alarms)."
  value       = aws_sns_topic.alerts.arn
}

output "alb_logs_bucket" {
  description = "S3 bucket receiving ALB access logs."
  value       = aws_s3_bucket.alb_logs.id
}

output "app_log_group_name" {
  description = "CloudWatch log group for app logs."
  value       = aws_cloudwatch_log_group.app.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "rollback_alarm_names" {
  description = "Alarms that roll back an in-progress instance refresh."
  value       = [aws_cloudwatch_metric_alarm.target_5xx.alarm_name, aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name]
}

output "instance_warmup" {
  description = "Instance warmup in seconds, reused by scripts/rollout.sh."
  value       = var.instance_warmup
}

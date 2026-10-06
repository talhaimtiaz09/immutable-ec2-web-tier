output "db_instance_identifier" {
  description = "RDS instance identifier (CloudWatch DBInstanceIdentifier dimension)."
  value       = aws_db_instance.this.identifier
}

output "endpoint" {
  description = "DB hostname (no port)."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "DB port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the initial database."
  value       = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "ARN of the RDS-managed Secrets Manager secret holding the master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key encrypting storage and the master secret."
  value       = aws_kms_key.this.arn
}

output "security_group_id" {
  description = "ID of the DB security group."
  value       = aws_security_group.this.id
}

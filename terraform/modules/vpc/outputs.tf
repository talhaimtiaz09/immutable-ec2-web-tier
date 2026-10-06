output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Primary CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability Zones the subnets span."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, fck-nat)."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "Private app subnet IDs (ASG instances). Egress through fck-nat."
  value       = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  description = "Isolated DB subnet IDs (RDS subnet group). No default route."
  value       = aws_subnet.db[*].id
}

output "nat_instance_id" {
  description = "Instance ID of the fck-nat instance."
  value       = aws_instance.fck_nat.id
}

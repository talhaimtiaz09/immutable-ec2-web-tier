# rds

Private Postgres for the app tier: `db.t4g.micro`, single-AZ, in the DB subnet
group, `publicly_accessible = false`. Storage and the master secret share one
customer-managed KMS key. `manage_master_user_password = true`, so RDS creates
and rotates the master password in Secrets Manager and no password ever exists
in Terraform. The security group allows 5432 only from one input SG.

Lab settings, all deliberate: single-AZ, 1-day backup retention (enough for
point-in-time restore), no deletion protection, no final snapshot.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix and DB identifier |
| `vpc_id` | string | required | VPC for the DB security group |
| `subnet_ids` | list(string) | required | DB subnets (2+ AZs) |
| `allowed_security_group_id` | string | required | SG allowed on 5432 (the app tier) |
| `engine_version` | string | `16` | Postgres version |
| `instance_class` | string | `db.t4g.micro` | Instance class |
| `allocated_storage` | number | `20` | GiB, gp3 |
| `db_name` | string | `app` | Initial database |
| `master_username` | string | `app_admin` | Master user (password managed by RDS) |
| `backup_retention_days` | number | `1` | Automated backup / PITR window (1-35) |
| `tags` | map(string) | `{}` | Tags for all resources |

## Outputs

| Name | Description |
|---|---|
| `endpoint` | DB hostname |
| `port` | DB port |
| `db_name` | Initial database name |
| `db_instance_identifier` | Instance identifier (CloudWatch dimension) |
| `master_user_secret_arn` | RDS-managed master secret ARN |
| `kms_key_arn` | CMK for storage and the secret |
| `security_group_id` | DB security group ID |

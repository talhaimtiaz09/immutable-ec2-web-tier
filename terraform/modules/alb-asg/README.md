# alb-asg

The immutable web tier. An internet-facing ALB forwards to an Auto Scaling
group of golden-AMI instances in the private app subnets.

- **Security groups chain by reference:** ALB SG -> app SG -> DB SG. There is
  no port 22 and no key pair. Access is through SSM Session Manager.
- **Health check** on the shallow `/healthz`, with `deregistration_delay` tuned
  to the app's graceful shutdown.
- **Launch template:** `ami_id` input (must exist and be owned by this account),
  IMDSv2 required, encrypted gp3 root volume, and user data that passes the DB
  endpoint and secret ARN (never the secret value).
- **Instance role:** `AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy`,
  `secretsmanager:GetSecretValue` on the one DB secret, and `kms:Decrypt` on its
  key via Secrets Manager only.
- **ASG:** `health_check_type = "ELB"`, min 2 / max 4, target tracking on
  `ALBRequestCountPerTarget`. The ASG pins a numbered launch template version,
  never `$Latest`, because rollback needs one.
- **Instance refresh:** not started by Terraform. The ASG ignores changes to
  its launch template; Terraform creates each new version and
  `scripts/rollout.sh` starts a Rolling refresh with it as
  `DesiredConfiguration`, `MinHealthyPercentage = 100`,
  `MaxHealthyPercentage = 200`, `InstanceWarmup = var.instance_warmup`,
  `AutoRollback = true` and an alarm specification on
  `aws_cloudwatch_metric_alarm.target_5xx` and
  `aws_cloudwatch_metric_alarm.unhealthy_hosts`.
- **Observability:** CloudWatch agent config in SSM Parameter Store, pulled at
  boot. App log group. Alarms for target 5xx, unhealthy hosts and p95 latency go
  to an SNS email topic. A small dashboard.
- **Optional HTTPS:** set `domain_name` to get a Route 53 zone lookup, an ACM
  certificate with DNS validation, a 443 listener, an 80->443 redirect and an
  alias record.
- **ALB access logs** go to an S3 bucket (SSE-S3, the only option ALB log
  delivery supports). The bucket policy grants the
  `logdelivery.elasticloadbalancing.amazonaws.com` principal, scoped by
  `aws:SourceArn`.

**Why the refresh lives outside Terraform:** AWS rolls a failed refresh back
to the configuration saved on the ASG *before* the refresh started. The
provider's `instance_refresh` block saves the new launch template version on
the ASG first, so an alarm-triggered rollback would redeploy the bad AMI.
Starting the refresh with `DesiredConfiguration` from `scripts/rollout.sh`
keeps the old version saved until the refresh succeeds.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix (<= 26 chars) |
| `vpc_id` | string | required | VPC ID |
| `public_subnet_ids` | list(string) | required | ALB subnets |
| `app_subnet_ids` | list(string) | required | ASG subnets |
| `ami_id` | string | required | Golden AMI (`^ami-[0-9a-f]+$`) |
| `instance_type` | string | `t4g.small` | arm64 instance type |
| `root_volume_size` | number | `10` | Root gp3 GiB |
| `app_port` | number | `8080` | App listen port |
| `app_service_name` | string | `app` | systemd unit restarted by user data |
| `app_log_path` | string | `/var/log/app/app.log` | Log file the agent ships |
| `log_retention_days` | number | `14` | App log group retention |
| `min_size` / `max_size` | number | `2` / `4` | ASG bounds |
| `instance_warmup` | number | `120` | Seconds to serving; refresh warmup, scaling warmup, grace period |
| `target_requests_per_instance` | number | `300` | ALBRequestCountPerTarget target |
| `health_check_path` | string | `/healthz` | Shallow liveness path |
| `deregistration_delay` | number | `30` | ALB drain seconds |
| `access_log_retention_days` | number | `7` | ALB log expiry |
| `domain_name` | string | `null` | FQDN for HTTPS; null = HTTP only |
| `hosted_zone_name` | string | `null` | Route 53 zone; defaults to `domain_name` |
| `db_endpoint`, `db_port`, `db_name` | | required / `5432` / required | Passed to instances |
| `db_secret_arn` | string | required | The only secret the role can read |
| `db_secret_kms_key_arn` | string | required | Key for that secret |
| `db_security_group_id` | string | required | App SG egress target |
| `db_instance_identifier` | string | required | Dashboard DB widget |
| `alarm_email` | string | required | SNS email subscriber |
| `target_5xx_threshold` | number | `5` | 5xx per minute that alarms and rolls back |
| `p95_latency_threshold_seconds` | number | `0.5` | p95 alarm threshold |
| `tags` | map(string) | `{}` | Tags, also propagated to instances and volumes |

## Outputs

| Name | Description |
|---|---|
| `alb_dns_name` | ALB DNS name |
| `app_url` | `https://<domain>` or `http://<alb dns>` |
| `alb_arn_suffix`, `target_group_arn_suffix` | CloudWatch dimensions |
| `asg_name` | ASG name |
| `launch_template_id`, `launch_template_latest_version` | Launch template |
| `app_security_group_id`, `alb_security_group_id` | Security groups |
| `instance_role_name` | Instance role |
| `alerts_topic_arn` | SNS alerts topic |
| `alb_logs_bucket` | Access log bucket |
| `app_log_group_name` | App log group |
| `dashboard_name` | Dashboard name |
| `rollback_alarm_names` | Alarms gating instance refresh |

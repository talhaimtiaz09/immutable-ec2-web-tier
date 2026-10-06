# The immutable web tier: ALB -> target group -> ASG of golden-AMI instances.
#
# - Security groups chain by reference: internet -> ALB SG -> app SG -> DB SG.
#   No CIDR-based ingress to the app tier and no port 22 anywhere. Operators use
#   SSM Session Manager.
# - A new ami_id makes a new launch template version, which starts a Rolling
#   instance refresh: new instances launch before old ones go (min healthy
#   100%), and the refresh rolls back if the 5xx or unhealthy-host alarm fires.
# - The ALB health check is the shallow /healthz. A DB blip must not make the
#   ASG replace a healthy fleet; deep checks belong in alarms, not replacement.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  https_enabled = var.domain_name != null
  zone_name     = coalesce(var.hosted_zone_name, var.domain_name, "unused")

  cw_agent_parameter_name = "AmazonCloudWatch-${var.name}" # prefix CloudWatchAgentServerPolicy can read
  app_log_group_name      = "/${var.name}/app"
  access_logs_prefix      = "alb"
}

# The AMI must exist and be ours. Its root device name drives the launch
# template's block device mapping, so the encrypted gp3 settings actually apply.
data "aws_ami" "app" {
  owners = ["self"]

  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "${var.name}: public ALB. HTTP/HTTPS in, app port out to the app SG only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS when a domain is set)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = local.https_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To app instances on the app port"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "${var.name}: app instances. App port from the ALB SG only; no SSH."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port from the ALB SG"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "Postgres to the DB SG"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = var.db_security_group_id
}

# AWS APIs (SSM, Secrets Manager, CloudWatch) through fck-nat, and S3 through
# the gateway endpoint. Interface endpoints would allow a VPC-only rule but cost
# ~$7/month each per AZ (see modules/vpc).
#trivy:ignore:AWS-0104 HTTPS-only egress to AWS public endpoints via NAT; endpoint-only egress is a production upgrade.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs via fck-nat / S3 gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# ALB access logs bucket
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0089 This IS the log bucket; logging it to another bucket is out of scope for the lab.
#trivy:ignore:AWS-0090 Access logs are append-only and expire after a few days; versioning adds nothing.
resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"

  # Lab: destroyed every session, logs and all.
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB access logs support SSE-S3 only; SSE-KMS makes log delivery fail.
#trivy:ignore:AWS-0132 ALB access log delivery does not support SSE-KMS.
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

# The log-delivery service principal is AWS's current recommendation for every
# region, including the pre-August-2022 ones like us-east-1 that used to need
# the regional ELB account ID. Scoped to this account's prefix and to load
# balancers in this account and region.
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "ElbLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/${local.access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:elasticloadbalancing:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# ---------------------------------------------------------------------------
# ALB, target group, listeners
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0053 Internet-facing by design: this is the public entry point.
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = false # lab: destroyed every session

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = local.access_logs_prefix
    enabled = true
  }

  tags = var.tags

  # ELB validates bucket access when logging is enabled, so the policy must
  # exist first. It also means destroy disables logging before the bucket goes.
  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_lb_target_group" "app" {
  name     = "${var.name}-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # Must cover the app's graceful shutdown: in-flight requests finish while the
  # target drains, then the ASG terminates it. Keep in sync with the app's
  # SIGTERM drain timeout (shorter than this).
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = var.tags
}

# Plain HTTP: forwards when no domain is set; redirects to HTTPS when it is.
#trivy:ignore:AWS-0054 HTTPS is optional in the lab (domain_name = null); with a domain this listener only redirects.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.https_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }

  dynamic "default_action" {
    for_each = local.https_enabled ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Optional HTTPS: Route 53 zone lookup, ACM cert with DNS validation, 443 listener
# ---------------------------------------------------------------------------

data "aws_route53_zone" "this" {
  count = local.https_enabled ? 1 : 0

  name         = local.zone_name
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  count = local.https_enabled ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.https_enabled ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.https_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = var.tags
}

resource "aws_route53_record" "alb" {
  count = local.https_enabled ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# Instance role: SSM, CloudWatch agent, and read access to ONE secret
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Least privilege: this one secret, and decrypt with this one key. Reading any
# other secret returns AccessDenied (drill 6).
data "aws_iam_policy_document" "db_secret_read" {
  statement {
    sid       = "ReadDbMasterSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid       = "DecryptDbMasterSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.db_secret_kms_key_arn]

    # Only when Secrets Manager is the caller on the instance's behalf.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "db_secret_read" {
  name   = "db-secret-read"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.db_secret_read.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
  tags = var.tags
}

# ---------------------------------------------------------------------------
# CloudWatch agent config (pulled from SSM at boot) and app log group
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0017 App logs carry no secrets; a CMK per log group is a production upgrade.
resource "aws_cloudwatch_log_group" "app" {
  name              = local.app_log_group_name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# EC2 doesn't publish memory or disk metrics; the agent does. The parameter name
# starts with AmazonCloudWatch- so CloudWatchAgentServerPolicy can read it.
resource "aws_ssm_parameter" "cw_agent" {
  name        = local.cw_agent_parameter_name
  description = "CloudWatch agent config for ${var.name} app instances."
  type        = "String"
  tier        = "Standard"

  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
    }
    metrics = {
      namespace = "CWAgent"
      append_dimensions = {
        AutoScalingGroupName = "$${aws:AutoScalingGroupName}"
        InstanceId           = "$${aws:InstanceId}"
      }
      aggregation_dimensions = [["AutoScalingGroupName"]]
      metrics_collected = {
        mem = {
          measurement = ["mem_used_percent"]
        }
        disk = {
          measurement = ["used_percent"]
          resources   = ["/"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [{
            file_path       = var.app_log_path
            log_group_name  = aws_cloudwatch_log_group.app.name
            log_stream_name = "{instance_id}"
          }]
        }
      }
    }
  })

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Launch template and Auto Scaling group
# ---------------------------------------------------------------------------

resource "aws_launch_template" "app" {
  name                   = "${var.name}-app"
  description            = "${var.name}: golden AMI app instances"
  image_id               = data.aws_ami.app.id
  instance_type          = var.instance_type
  update_default_version = true

  # No key_name: there is no SSH. Access is SSM Session Manager only.

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = data.aws_ami.app.root_device_name

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = false # 5-minute basic metrics; the agent covers memory/disk
  }

  # Runtime config only (where the DB is, which secret to read). The app and
  # agent are baked into the AMI. No secret values here: just the secret ARN.
  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region             = data.aws_region.current.name
    ami_id             = var.ami_id
    db_host            = var.db_endpoint
    db_port            = var.db_port
    db_name            = var.db_name
    db_secret_arn      = var.db_secret_arn
    app_port           = var.app_port
    app_service_name   = var.app_service_name
    cw_agent_parameter = aws_ssm_parameter.cw_agent.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.name}-app", AmiId = var.ami_id })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.name}-app" })
  }

  tags = var.tags
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.name}-asg"
  vpc_zone_identifier = var.app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size = var.min_size
  max_size = var.max_size
  # desired_capacity is left to target tracking; it starts at min_size.

  # Replace instances the ALB marks unhealthy, not only ones EC2 reports dead.
  health_check_type         = "ELB"
  health_check_grace_period = var.instance_warmup
  default_instance_warmup   = var.instance_warmup

  # A numbered version, never $Latest: instance refresh can only roll back to
  # a specific launch template version. Only used when the ASG is created.
  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Rollouts are started by scripts/rollout.sh, not by Terraform. AWS rolls a
  # failed refresh back to the configuration saved on the ASG *before* the
  # refresh started, and the provider's instance_refresh block saves the new
  # launch template version first, so a rollback would land on the new AMI.
  # Terraform creates each new launch template version; the ASG keeps the old
  # one until a refresh started with DesiredConfiguration succeeds.
  lifecycle {
    ignore_changes = [launch_template]
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = false # instance tags come from the launch template
  }

  dynamic "tag" {
    for_each = var.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = false
    }
  }
}

# Scale on load per instance. resource_label ties the metric to this ALB and
# target group: "<alb arn_suffix>/<target group arn_suffix>".
resource "aws_autoscaling_policy" "requests_per_target" {
  name                   = "${var.name}-requests-per-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.target_requests_per_instance

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}

# ---------------------------------------------------------------------------
# Alerting: SNS email topic and alarms
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0095 Alarm notifications carry no sensitive data; CloudWatch can't publish to topics encrypted with the AWS-managed SNS key, and a CMK is a production upgrade.
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

# Email subscriptions stay "pending confirmation" until the link is clicked.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# The two alarms below gate instance refresh (scripts/rollout.sh). treat_missing_data must be
# notBreaching: no 5xx means no datapoints, and an alarm in INSUFFICIENT_DATA
# makes StartInstanceRefresh fail outright.
resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name        = "${var.name}-target-5xx"
  alarm_description = "Targets returned 5xx. Also triggers instance refresh rollback."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HTTPCode_Target_5XX_Count"
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.target_5xx_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name        = "${var.name}-unhealthy-hosts"
  alarm_description = "At least one target failed /healthz. Also triggers instance refresh rollback."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "UnHealthyHostCount"
  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "p95_latency" {
  alarm_name          = "${var.name}-p95-latency"
  alarm_description   = "p95 target response time above ${var.p95_latency_threshold_seconds}s for 3 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix }
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.p95_latency_threshold_seconds
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Dashboard: requests, latency, healthy hosts, ASG size, DB connections
# ---------------------------------------------------------------------------

locals {
  region  = data.aws_region.current.name
  alb_dim = ["LoadBalancer", aws_lb.this.arn_suffix]
  tg_dims = ["TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix]

  dashboard_widgets = [
    {
      type = "metric", x = 0, y = 0, width = 12, height = 6
      properties = {
        title  = "Requests and 5xx"
        region = local.region
        stat   = "Sum"
        period = 60
        metrics = [
          concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim),
          concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim),
          concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim),
        ]
      }
    },
    {
      type = "metric", x = 12, y = 0, width = 12, height = 6
      properties = {
        title  = "Target response time (s)"
        region = local.region
        period = 60
        metrics = [
          concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p50" }]),
          concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95" }]),
        ]
      }
    },
    {
      type = "metric", x = 0, y = 6, width = 8, height = 6
      properties = {
        title  = "Target health"
        region = local.region
        stat   = "Maximum"
        period = 60
        metrics = [
          concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dims),
          concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg_dims),
        ]
      }
    },
    {
      type = "metric", x = 8, y = 6, width = 8, height = 6
      properties = {
        title  = "ASG size"
        region = local.region
        stat   = "Maximum"
        period = 60
        metrics = [
          ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.app.name],
          ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.app.name],
        ]
      }
    },
    {
      type = "metric", x = 16, y = 6, width = 8, height = 6
      properties = {
        title  = "DB connections and CPU"
        region = local.region
        period = 60
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Maximum" }],
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_identifier, { stat = "Average", yAxis = "right" }],
        ]
      }
    },
    {
      type = "metric", x = 0, y = 12, width = 24, height = 6
      properties = {
        title  = "Instance memory and disk (CloudWatch agent)"
        region = local.region
        stat   = "Average"
        period = 60
        metrics = [
          ["CWAgent", "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app.name],
          ["CWAgent", "disk_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app.name],
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}

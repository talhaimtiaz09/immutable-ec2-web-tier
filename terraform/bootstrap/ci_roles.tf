# GitHub Actions -> AWS through OIDC. No AWS keys in GitHub. Each role trusts
# one repo and one exact `sub` claim:
#
#   plan        repo:<repo>:pull_request         PR jobs (read-only + state lock)
#   apply       repo:<repo>:environment:<env>    jobs with `environment: lab`
#   ami-builder repo:<repo>:ref:refs/heads/main  pushes to main (Packer)
#
# A job that declares `environment:` gets the environment form of `sub`, NOT
# the ref form, so the apply role is bound to the GitHub Environment. Restrict
# that environment to the main branch and require a reviewer in repo settings.

# ---------------------------------------------------------------------------
# OIDC provider (one per account per URL; may already exist)
# ---------------------------------------------------------------------------

# thumbprint_list is omitted: AWS validates GitHub's certificate through its
# own trusted CA library, and the provider no longer requires it.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]

  tags = local.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.github_oidc_host}"
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    plan        = "repo:${var.github_repository}:pull_request"
    apply       = "repo:${var.github_repository}:environment:${var.github_environment}"
    ami-builder = "repo:${var.github_repository}:ref:refs/heads/main"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# ---------------------------------------------------------------------------
# Plan role: read-only, plus what `terraform plan` writes (the lock object)
# ---------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  description          = "GitHub Actions: terraform plan on pull requests (read-only)."
  assume_role_policy   = data.aws_iam_policy_document.github_trust["plan"].json
  max_session_duration = 3600

  tags = local.tags
}

# Plan refreshes every resource, so it needs broad read. ReadOnlyAccess is the
# deliberate trade-off over a hand-maintained Describe* list.
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.state_objects_arn]
  }

  # Native S3 locking writes <key>.tflock even during plan and deletes it after.
  statement {
    sid       = "WriteLockObjectOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = [local.lock_objects_arn]
  }

  # Decrypt state; Encrypt/GenerateDataKey to write the SSE-KMS lock object.
  statement {
    sid       = "StateKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state.json
}

# ---------------------------------------------------------------------------
# Apply role: read-only plus write access to the services envs/lab uses
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  description          = "GitHub Actions: terraform apply for envs/${var.environment} (GitHub Environment ${var.github_environment})."
  assume_role_policy   = data.aws_iam_policy_document.github_trust["apply"].json
  max_session_duration = 3600

  tags = local.tags
}

# Same reason as the plan role: refresh reads everything Terraform manages.
resource "aws_iam_role_policy_attachment" "apply_readonly" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "apply_state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadWriteState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_objects_arn]
  }

  statement {
    sid       = "StateKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state-read-write"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_state.json
}

# Compute and network. Deliberately broad within the region: Terraform drives
# dozens of EC2/ELB/ASG/RDS APIs (VPC, subnets, routes, SGs, endpoints, launch
# templates, instances, listeners...), and resource-level scoping for creates
# is impractical because the ARNs don't exist yet. Locked to var.region.
data "aws_iam_policy_document" "apply_compute" {
  statement {
    sid    = "ComputeNetworkDatabaseInRegion"
    effect = "Allow"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "rds:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # Optional HTTPS (domain_name set). Certificate and zone IDs aren't known
  # here, so this is account-wide within ACM/Route 53 record changes.
  statement {
    sid    = "AcmCertificates"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
      "acm:DeleteCertificate",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "Route53Records"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${local.partition}:route53:::hostedzone/*"]
  }
}

resource "aws_iam_policy" "apply_compute" {
  name        = "${var.project}-gha-apply-compute"
  description = "Apply role: EC2, ELB, Auto Scaling, RDS (region-locked), ACM, Route 53 records."
  policy      = data.aws_iam_policy_document.apply_compute.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_compute" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_compute.arn
}

# Keys, secrets, observability, logs bucket: scoped to workload-prefixed names
# wherever the service supports it.
data "aws_iam_policy_document" "apply_data" {
  # KMS key ARNs are random, so key management is region-locked rather than
  # ARN-scoped. The state key is protected by the explicit deny below.
  statement {
    sid    = "KmsWorkloadKeys"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
      "kms:EnableKeyRotation",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:UpdateKeyDescription",
      "kms:CreateGrant",
      "kms:RetireGrant",
      "kms:RevokeGrant",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid    = "ProtectStateKey"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion",
      "kms:DisableKey",
      "kms:PutKeyPolicy",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:UpdateAlias",
    ]
    resources = [aws_kms_key.state.arn, aws_kms_alias.state.arn]
  }

  # manage_master_user_password: RDS creates the secret with the caller's
  # permissions. RDS-managed secrets are always named rds!...
  statement {
    sid    = "RdsManagedSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:DeleteSecret",
      "secretsmanager:RotateSecret",
    ]
    resources = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:rds!*"]
  }

  statement {
    sid    = "CloudWatchAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
    ]
    resources = ["arn:${local.partition}:cloudwatch:${var.region}:${local.account_id}:alarm:${local.workload_prefix}-*"]
  }

  statement {
    sid       = "CloudWatchDashboards"
    effect    = "Allow"
    actions   = ["cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards"]
    resources = ["arn:${local.partition}:cloudwatch::${local.account_id}:dashboard/${local.workload_prefix}*"]
  }

  statement {
    sid    = "AppLogGroups"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${local.workload_prefix}/*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${local.workload_prefix}/*:*",
    ]
  }

  statement {
    sid    = "AlertTopics"
    effect = "Allow"
    actions = [
      "sns:CreateTopic",
      "sns:DeleteTopic",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:Unsubscribe",
      "sns:SetSubscriptionAttributes",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = ["arn:${local.partition}:sns:${var.region}:${local.account_id}:${local.workload_prefix}-*"]
  }

  statement {
    sid    = "CloudWatchAgentConfigParameter"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
    ]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/AmazonCloudWatch-${local.workload_prefix}*"]
  }

  # ALB access-log bucket and its sub-resources, only on "<prefix>-alb-logs-*"
  # buckets (the state bucket name doesn't match). Reads come from
  # ReadOnlyAccess; object deletes are for force_destroy on teardown.
  statement {
    sid    = "AlbLogsBucket"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketTagging",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
    ]
    resources = ["arn:${local.partition}:s3:::${local.workload_prefix}-alb-logs-*"]
  }

  statement {
    sid       = "AlbLogsObjectsTeardown"
    effect    = "Allow"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:${local.partition}:s3:::${local.workload_prefix}-alb-logs-*/*"]
  }
}

resource "aws_iam_policy" "apply_data" {
  name        = "${var.project}-gha-apply-data"
  description = "Apply role: KMS, RDS-managed secret, CloudWatch, logs, SNS, SSM agent config, ALB logs bucket."
  policy      = data.aws_iam_policy_document.apply_data.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_data" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_data.arn
}

# IAM: only workload-prefixed roles, instance profiles and policies, so the
# apply role can't touch the CI roles ("<project>-gha-*") or anything else.
# Residual risk, accepted for the lab: inline role policies can't be
# content-constrained. Production would add a permissions boundary condition.
#trivy:ignore:AWS-0342 PassRole is required to launch instances with the app instance profile; limited to workload-prefixed roles and EC2.
data "aws_iam_policy_document" "apply_iam" {
  statement {
    sid    = "WorkloadRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.workload_prefix}-*"]
  }

  # Managed policies: only the two AWS policies the instance role needs, or
  # workload-prefixed customer policies.
  statement {
    sid       = "AttachApprovedPolicies"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.workload_prefix}-*"]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
        "arn:${local.partition}:iam::${local.account_id}:policy/${local.workload_prefix}-*",
      ]
    }
  }

  statement {
    sid    = "WorkloadPolicies"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:policy/${local.workload_prefix}-*"]
  }

  statement {
    sid    = "WorkloadInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/${local.workload_prefix}-*"]
  }

  # PassRole: workload roles only, and only to EC2. IfExists because
  # AddRoleToInstanceProfile also checks PassRole without naming a service.
  statement {
    sid       = "PassWorkloadRolesToEc2"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.workload_prefix}-*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_policy" "apply_iam" {
  name        = "${var.project}-gha-apply-iam"
  description = "Apply role: IAM limited to ${local.workload_prefix}-* roles, instance profiles and policies."
  policy      = data.aws_iam_policy_document.apply_iam.json
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "apply_iam" {
  role       = aws_iam_role.apply.name
  policy_arn = aws_iam_policy.apply_iam.arn
}

# ---------------------------------------------------------------------------
# AMI builder role (used later by ami.yml / Packer over SSM)
# ---------------------------------------------------------------------------

# Instance profile for the temporary Packer build instance: SSM only, so Packer
# can connect with ssh_interface = "session_manager" and no port 22.
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

resource "aws_iam_role" "packer_instance" {
  name               = "${var.project}-packer-build"
  description        = "Temporary Packer build instance: SSM Session Manager only."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "packer_instance_ssm" {
  role       = aws_iam_role.packer_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "packer_instance" {
  name = "${var.project}-packer-build"
  role = aws_iam_role.packer_instance.name
  tags = local.tags
}

resource "aws_iam_role" "ami_builder" {
  name                 = "${var.project}-gha-ami-builder"
  description          = "GitHub Actions: Packer golden AMI builds from main."
  assume_role_policy   = data.aws_iam_policy_document.github_trust["ami-builder"].json
  max_session_duration = 3600

  tags = local.tags
}

# The EC2 action list Packer's amazon-ebs builder documents, region-locked.
# Resource-level scoping is limited because Packer creates the instance,
# temporary key pair, security group, volumes, snapshots and image on the fly.
# DeregisterImage/DeleteSnapshot also cover pruning old AMIs (keep the last 3).
data "aws_iam_policy_document" "ami_builder" {
  statement {
    sid    = "PackerEc2"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:CreateKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
      "ec2:ModifySnapshotAttribute",
      "ec2:CreateImage",
      "ec2:RegisterImage",
      "ec2:DeregisterImage",
      "ec2:CopyImage",
      "ec2:ModifyImageAttribute",
      "ec2:CreateTags",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:GetPasswordData",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # SSM Session Manager tunnel that Packer uses instead of a public port 22.
  statement {
    sid     = "PackerSsmSession"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/*",
      "arn:${local.partition}:ssm:${var.region}::document/AWS-StartPortForwardingSession",
    ]
  }

  statement {
    sid       = "PackerSsmSessionLifecycle"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:session/*"]
  }

  statement {
    sid       = "PackerSsmStatus"
    effect    = "Allow"
    actions   = ["ssm:DescribeInstanceInformation", "ssm:GetConnectionStatus", "ssm:DescribeSessions"]
    resources = ["*"]
  }

  # Base AMI lookup through the public AL2023 SSM parameters.
  statement {
    sid       = "BaseAmiParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${var.region}::parameter/aws/service/ami-amazon-linux-latest/*"]
  }

  statement {
    sid       = "PassPackerInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.packer_instance.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadPackerInstanceProfile"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = [aws_iam_instance_profile.packer_instance.arn]
  }
}

resource "aws_iam_role_policy" "ami_builder" {
  name   = "packer-ebs-ssm"
  role   = aws_iam_role.ami_builder.id
  policy = data.aws_iam_policy_document.ami_builder.json
}

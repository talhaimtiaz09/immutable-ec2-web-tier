# terraform

```
terraform/
├── bootstrap/        # once, locally: state bucket + KMS, GitHub OIDC, CI roles, budget
├── modules/
│   ├── vpc/          # 3 tiers x 2 AZs, fck-nat (t4g.nano), S3 gateway endpoint
│   ├── rds/          # private Postgres, CMK, RDS-managed master secret
│   └── alb-asg/      # ALB, launch template, ASG, rollback alarms, dashboard
├── envs/
│   └── lab/          # wires the modules; ami_id lives in lab.tfvars
└── .tflint.hcl
```

AWS provider `~> 5.70`, region `us-east-1`. Every resource is tagged
`Project`, `Owner`, `Environment` and `ManagedBy` through provider `default_tags`.

## 1. Bootstrap (once, admin credentials, local state)

```bash
cd terraform/bootstrap
cp bootstrap.tfvars.example bootstrap.tfvars   # budget email; OIDC provider flag
aws iam list-open-id-connect-providers         # already have GitHub's? set create_github_oidc_provider = false
terraform init
terraform apply -var-file=bootstrap.tfvars
terraform output
```

This creates the following:

- **State bucket:** versioned, SSE-KMS with a dedicated key, public access
  blocked, non-TLS requests denied. Locking uses S3's native lock file, so
  there's no DynamoDB table.
- **GitHub OIDC provider:** created, or looked up if it already exists.
- **`<project>-gha-plan`:** trusts `repo:talhaimtiaz09/immutable-ec2-web-tier:pull_request`.
  It has `ReadOnlyAccess`, state read, and put/delete on `*.tflock` only.
- **`<project>-gha-apply`:** trusts `repo:...:environment:lab`. It has
  read-only access plus write access to the services the lab uses. IAM is
  limited to `immutable-ec2-web-tier-lab-*` names, and `iam:PassRole` only to EC2.
- **`<project>-gha-ami-builder`:** trusts `repo:...:ref:refs/heads/main`. It has
  the EC2 and SSM permissions Packer needs to build over Session Manager, plus
  PassRole on the `<project>-packer-build` instance profile.
- **Monthly cost budget:** $10 by default, emails at 80% actual and 100%
  forecast.

Bootstrap keeps its own state in a local `terraform.tfstate` (gitignored).
Back it up, or migrate it into the bucket afterwards. It stays up between
sessions.

## 2. GitHub setup

- **Repository variables:** `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`,
  `TF_STATE_BUCKET` (from `terraform output`) and `ALARM_EMAIL`.
- **Environment `lab`:** add a required reviewer, and limit deployment branches
  to `main`.

## 3. Apply the lab

```bash
cd terraform/envs/lab
cp lab.tfvars.example lab.tfvars       # set ami_id; commit this file (no secrets in it)
terraform init -backend-config="bucket=<state_bucket>"
TF_VAR_alarm_email=you@example.com terraform plan -var-file=lab.tfvars
```

Outside of a first local test, changes go through CI. Confirm the SNS
subscription email after the first apply. **Destroy at the end of every
session** (~$2/day running):

```bash
terraform destroy -var-file=lab.tfvars
```

## How CI works (`.github/workflows/terraform.yml`)

**Pull request touching `terraform/`:**

1. Run `fmt -check`, then `init -backend=false` and `validate` on both roots.
2. Run `tflint --recursive` (AWS ruleset) and `trivy config`.
3. Assume the plan role through OIDC and run `terraform plan`.
4. Post the plan as a single PR comment that later runs update.

**Push to `main`:** the apply job runs in the `lab` environment. It waits for
the reviewer, assumes the apply role, plans the merged commit and applies that
saved plan.

There are no AWS keys anywhere. Actions are pinned to commit SHAs.

Deliberate lab trade-offs flagged by trivy are suppressed inline with a reason,
as `#trivy:ignore:<ID> <reason>`. They are:

- single-AZ RDS with short retention
- no VPC flow logs
- no CMK on SNS or the log group
- HTTP when no domain is set
- SSE-S3 on the ALB log bucket (the only option ALB supports)

## Validate locally without AWS credentials

```bash
docker run --rm -v "$PWD":/w -w /w/terraform hashicorp/terraform:1.16.5 fmt -check -recursive
docker run --rm -v "$PWD":/w -w /w/terraform/envs/lab hashicorp/terraform:1.16.5 init -backend=false
docker run --rm -v "$PWD":/w -w /w/terraform/envs/lab hashicorp/terraform:1.16.5 validate
```

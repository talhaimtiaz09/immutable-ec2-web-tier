# vpc

Three-tier VPC across two AZs: public (ALB, NAT), app (ASG) and db (RDS)
subnets, one `/24` each. Egress for the app tier goes through a single
[fck-nat](https://fck-nat.dev) `t4g.nano` instance, and S3 goes through a free
gateway endpoint. The db tier has no default route.

**Why no NAT gateway:** a managed NAT gateway is ~$32/month idle, and SSM
interface endpoints are ~$7/month each per AZ. fck-nat is ~$3/month. The cost is
a single NAT in one AZ: if it fails, app-tier egress stops until it's replaced.
Production would use a NAT gateway per AZ or interface endpoints.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | required | Name prefix for all resources |
| `cidr` | string | `10.20.0.0/16` | VPC CIDR |
| `az_count` | number | `2` | AZs per tier (2-10) |
| `nat_instance_type` | string | `t4g.nano` | fck-nat instance type (arm64) |
| `tags` | map(string) | `{}` | Tags for all resources |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | VPC ID |
| `vpc_cidr` | VPC CIDR |
| `azs` | AZs used |
| `public_subnet_ids` | Public subnets (ALB, fck-nat) |
| `app_subnet_ids` | Private app subnets (ASG) |
| `db_subnet_ids` | Isolated DB subnets |
| `nat_instance_id` | fck-nat instance ID |

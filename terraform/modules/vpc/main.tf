# Three-tier VPC across two AZs, written with plain resources (no community
# module) so every route is visible in review:
#
#   public  -> ALB + fck-nat; default route to the internet gateway
#   app     -> ASG instances; default route to the fck-nat ENI, S3 via gateway endpoint
#   db      -> RDS only; no default route at all
#
# Cost: a managed NAT gateway is ~$32/month idle plus data processing, and SSM
# interface endpoints are ~$7/month each per AZ. A single fck-nat t4g.nano is
# ~$3/month and the S3 gateway endpoint is free. The trade-off is one NAT in one
# AZ: if it dies, app-tier egress stops until it is replaced. Golden AMIs have
# packages baked in, so egress is only AWS APIs (SSM, Secrets Manager, CloudWatch).

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /24 per subnet, carved out of the VPC CIDR: public 0-9, app 10-19, db 20-29.
  public_subnets = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i)]
  app_subnets    = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i + 10)]
  db_subnets     = [for i in range(var.az_count) : cidrsubnet(var.cidr, 8, i + 20)]
}

#trivy:ignore:AWS-0178 Lab trade-off: VPC flow logs cost more than the rest of the network; enable for production.
resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Strip the default security group of all rules so nothing can fall back to it.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-default-deny" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

# No auto-assigned public IPs: the ALB doesn't need them and fck-nat asks for
# one explicitly.
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" })
}

resource "aws_subnet" "app" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-app-${local.azs[count.index]}", Tier = "app" })
}

resource "aws_subnet" "db" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.db_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, { Name = "${var.name}-db-${local.azs[count.index]}", Tier = "db" })
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table for both app subnets: there is only one NAT to point at.
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_route" "app_nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fck_nat.primary_network_interface_id
}

resource "aws_route_table_association" "app" {
  count = var.az_count

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

# DB tier: local routes only. RDS never initiates outbound connections.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_route_table_association" "db" {
  count = var.az_count

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# Free S3 gateway endpoint: S3 traffic (AL2023 repos, CloudWatch agent bits)
# skips the NAT entirely.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

# ---------------------------------------------------------------------------
# fck-nat: a NAT instance from the official fck-nat AMI (https://fck-nat.dev)
# ---------------------------------------------------------------------------

data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"] # fck-nat publisher account

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "fck_nat" {
  name        = "${var.name}-fck-nat"
  description = "fck-nat: forward traffic from the app subnets to the internet."
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-fck-nat" })
}

# Only the app tier is routed through the NAT, so only its CIDRs may reach it.
resource "aws_vpc_security_group_ingress_rule" "fck_nat_from_app" {
  for_each = toset(local.app_subnets)

  security_group_id = aws_security_group.fck_nat.id
  description       = "All traffic from app subnet ${each.value} (NAT forwarding)"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

#trivy:ignore:AWS-0104 A NAT forwards arbitrary outbound traffic by definition; the app SG limits what reaches it.
resource "aws_vpc_security_group_egress_rule" "fck_nat_all" {
  security_group_id = aws_security_group.fck_nat.id
  description       = "NAT egress to the internet"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "fck_nat" {
  ami           = data.aws_ami.fck_nat.id
  instance_type = var.nat_instance_type
  subnet_id     = aws_subnet.public[0].id

  vpc_security_group_ids      = [aws_security_group.fck_nat.id]
  associate_public_ip_address = true
  source_dest_check           = false # required for any instance that forwards packets

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name}-fck-nat" })

  lifecycle {
    # A new fck-nat release would otherwise replace the NAT (and cut egress) on
    # an unrelated apply. The lab is rebuilt each session, which picks it up.
    ignore_changes = [ami]
  }
}

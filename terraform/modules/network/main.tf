# Network module
#
# Builds the network the whole system runs in. The layout follows one rule:
# only what must face the internet is public.
#
#   public subnets (2 AZs)        load balancer and NAT gateway only
#   private app subnets (2 AZs)   the application containers
#   private tooling subnet (AZ A) the Jenkins server, apart from the app
#
# Nothing in a private subnet has a public IP or a route from the internet.
# Private subnets can reach the internet only outbound, through the NAT gateway.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  # Skips Local Zones and other zones that need opt-in.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Two Availability Zones, so the app survives the loss of one.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- VPC ------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-vpc"
  }
}

# The default security group allows all traffic between its members. Emptying it
# means anything accidentally placed in it can talk to nothing (CIS benchmark).
# Every real resource gets its own purpose-built security group instead.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-default-sg-locked"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.project}-igw"
  }
}

# --- Subnets --------------------------------------------------------------
# No subnet hands out public IPs automatically, so nothing can become public by
# accident. The only public addresses are the load balancer and the NAT gateway.

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-public-${substr(local.azs[count.index], -1, 1)}"
    Tier = "public"
  }
}

resource "aws_subnet" "private_app" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_app_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-private-app-${substr(local.azs[count.index], -1, 1)}"
    Tier = "private-app"
  }
}

resource "aws_subnet" "private_tooling" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_tooling_subnet_cidr
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-private-tooling-${substr(local.azs[0], -1, 1)}"
    Tier = "private-tooling"
  }
}

# --- Internet access ------------------------------------------------------
# One NAT gateway in public subnet A. Private resources use it to reach GitHub,
# ECR and AWS APIs. It only allows connections that start inside the VPC.
#
# One NAT is a cost choice and a single point of failure: if AZ A fails,
# private resources lose outbound internet. Running tasks keep serving users,
# but new deployments and image pulls would fail until it is back. A regional
# NAT gateway, or one NAT per AZ, is the resilience upgrade.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.project}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# --- Route tables ---------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.project}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets send internet-bound traffic to the NAT gateway and have no
# route to the internet gateway, so nothing on the internet can start a
# connection to them.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.project}-private-rt"
  }
}

resource "aws_route_table_association" "private_app" {
  count = 2

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_tooling" {
  subnet_id      = aws_subnet.private_tooling.id
  route_table_id = aws_route_table.private.id
}

# --- VPC Flow Logs --------------------------------------------------------
# Records who talked to whom (accepted and rejected) across the whole VPC. This
# is the audit trail for network investigations. Encrypted with the project key.

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.project}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.kms_key_arn
}

# The role VPC Flow Logs uses to write into the log group. Only the Flow Logs
# service, acting for this account, can use it, and it can write only there.
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }

  statement {
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "${var.project}-vpc-flow-log"
  }
}

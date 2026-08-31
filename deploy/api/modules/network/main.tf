# A purpose-built VPC for the serving plane.
#
# Deliberately not the default VPC. The account's default (172.31.0.0/16) has
# six subnets, all public, which is the wrong shape: the tasks should have no
# route in from the internet at all, and the only public thing here should be
# the load balancer.
#
# The S3 gateway endpoint at the bottom is the load-bearing piece. This service
# is almost entirely object reads, and without it every one of them would leave
# via NAT and be billed per gigabyte.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  azs = var.availability_zones

  # /20 per subnet out of a /16. Public subnets take the low indices, private
  # subnets start at 8, which leaves a contiguous gap for subnets this change
  # does not create yet rather than interleaving them.
  public_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_count = var.single_nat_gateway ? 1 : length(local.azs)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

# --- Public subnets: the load balancer, and nothing else -------------------

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # The ALB gets its public addresses from the load balancer itself. Nothing
  # launched into these subnets should acquire one by default.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: the tasks --------------------------------------------

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

# One route table per AZ even when there is a single NAT gateway, so switching
# single_nat_gateway to false later is a route change rather than a
# re-association of every subnet.
resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_default" {
  count = length(local.azs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- S3 gateway endpoint ----------------------------------------------------

# Free, regional, and the reason compute has to sit in the same region as the
# buckets (A5). Without it every object read is NAT egress billed per gigabyte,
# on a service whose whole workload is object reads. The account has no VPC
# endpoints today, so this is built rather than adopted.
#
# route_table_ids is intentionally NOT set here. A gateway endpoint is
# per-VPC-per-service, and the batch plane (provision-cron-aws, E5) shares this
# VPC and this endpoint rather than standing up its own. That root reads
# vpc_id/s3_endpoint_id via terraform_remote_state and associates its own
# route tables with aws_vpc_endpoint_route_table_association below -- a
# separate resource per table, not the route_table_ids attribute, because that
# attribute is a full-replacement list: whichever root sets it would silently
# drop any association the other root created on its next apply. This root
# manages its own two associations the same way, so both roots use the same
# mechanism rather than one being a special case.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

resource "aws_vpc_endpoint_route_table_association" "s3_private" {
  count = length(aws_route_table.private)

  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  route_table_id  = aws_route_table.private[count.index].id
}

data "aws_region" "current" {}

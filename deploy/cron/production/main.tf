# The AWS batch scanning plane's network and test-bucket resources.
# provision-cron-aws groups 2-3. See openspec/changes/provision-cron-aws/.
#
# This root does not build its own VPC. E5 shares deploy/api's
# scorecard-api-production VPC and its single NAT Gateway rather than
# provisioning a second one -- cost-driven, not capacity-driven (design.md).
# VPC context (vpc_id, the NAT Gateway to route through, the AZs to land in,
# the S3 gateway endpoint to associate with) is read from that root's state
# via terraform_remote_state, resolved in task 3.1. It is a read-only,
# one-direction dependency: this root never writes into deploy/api's state,
# and deploy/api/modules/network never references this one.
#
# The S3 gateway endpoint itself is not duplicated -- a gateway endpoint is
# per-VPC-per-service, so a second one cannot coexist with deploy/api's. This
# root instead adds its own aws_vpc_endpoint_route_table_association
# resources against that endpoint's ID, the same mechanism
# deploy/api/modules/network now uses for its own two associations, so
# neither root's apply can silently drop the other's association by treating
# route_table_ids as an authoritative full-replacement list.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial configuration; bucket supplied at init:
  #   tofu init -backend-config=bucket=<state bucket>
  backend "s3" {
    key          = "cron/production/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    Project   = "scorecard"
    Component = "cron"
    ManagedBy = "opentofu"
    Source    = "ossf/scorecard-infra//deploy/cron/production"
  }

  vpc_id         = data.terraform_remote_state.api_production.outputs.vpc_id
  azs            = data.terraform_remote_state.api_production.outputs.availability_zones
  s3_endpoint_id = data.terraform_remote_state.api_production.outputs.s3_endpoint_id

  # single_nat_gateway defaults true on deploy/api/modules/network, so
  # production has exactly one NAT Gateway; this shares it rather than
  # picking per-AZ (E5).
  nat_gateway_id = data.terraform_remote_state.api_production.outputs.nat_gateway_ids[0]
}

data "terraform_remote_state" "api_production" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "api/production/terraform.tfstate"
    region = var.region
  }
}

# Read-only, same reasoning as api_production above: deploy/cron/secrets
# already creates the github/gitlab Secrets Manager containers (its own
# separate root, key cron/secrets/terraform.tfstate in the same bucket) --
# this root only needs their ARNs and combined read policy for group 5's
# Pod Identity roles, not to manage the secrets themselves.
data "terraform_remote_state" "cron_secrets" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "cron/secrets/terraform.tfstate"
    region = var.region
  }
}

# Adopted, never managed (E6) -- the controller's only access is read-only,
# so there is no test counterpart to point at instead (E7).
data "aws_s3_bucket" "input_projects" {
  bucket = "ossf-scorecard-input-projects"
}

# --- Network: private subnets for the batch cluster, in the shared VPC -----

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = local.vpc_id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "scorecard-cron-production-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  count = length(local.azs)

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "scorecard-cron-production-private-${local.azs[count.index]}"
  })
}

resource "aws_route" "private_default" {
  count = length(local.azs)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = local.nat_gateway_id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_vpc_endpoint_route_table_association" "s3_private" {
  count = length(aws_route_table.private)

  vpc_endpoint_id = local.s3_endpoint_id
  route_table_id  = aws_route_table.private[count.index].id
}

# --- Storage: three test buckets (E7), genuinely created ---------------------
#
# Not the six adopted corpus buckets (E6) -- those stay data sources in a
# later task, never declared as resources here. These are new, so they get
# versioning, which the 2026-08-31 capture confirmed is off on all six
# adopted buckets: no reason to reproduce that gap in a bucket whose whole
# purpose is catching a bad write before it reaches production.

resource "aws_s3_bucket" "test" {
  for_each = var.test_buckets

  bucket = each.value

  tags = merge(local.tags, { Name = each.value })
}

resource "aws_s3_bucket_versioning" "test" {
  # for_each over var.test_buckets, not aws_s3_bucket.test -- the latter drags
  # in every deprecated attribute on aws_s3_bucket (acl, policy,
  # website_domain, ...) as a for_each dependency even though only .id is
  # read, which the AWS provider surfaces as spurious deprecation warnings on
  # every plan.
  for_each = var.test_buckets

  bucket = aws_s3_bucket.test[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "test" {
  for_each = var.test_buckets

  bucket = aws_s3_bucket.test[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "test" {
  for_each = var.test_buckets

  bucket = aws_s3_bucket.test[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Storage: versioning on the six adopted corpus buckets (E6) --------------
#
# The gate on writing production results at all. Two of the four buckets this
# pipeline touches overwrite by design -- cron-results' <repo>/results.json and
# <repo>/raw.json are the "latest" pointers the live API reads as its fallback,
# and cii-data's <repo>/result.json is rewritten every refresh -- and with
# versioning off, a bad run destroys the previous week irrecoverably. data2 and
# rawdata are keyed YYYY.MM.DD/HHMMSS/ and cannot collide, but a corpus where
# only some buckets are recoverable is a corpus nobody can reason about under
# pressure, so all six get it.
#
# E6 says never declare these as aws_s3_bucket, and that still holds: the rule
# protects against OpenTofu deleting the corpus when a block is removed, which
# only aws_s3_bucket can do. These sub-resources take a bucket *name*, so
# versioning and lifecycle can be managed without the bucket ever entering
# state as a deletable resource. Removing one of these blocks stops managing a
# setting; it destroys nothing.
#
# ossf-scorecard-results is written by api/'s POST path, not by cron, and
# deploy/api/environments/production reads it as a data source. It is here
# because the durability decision was made for the corpus as a whole and one
# root is easier to reason about than two -- but if deploy/api ever wants to
# own its own bucket's lifecycle, this is the block to move.
locals {
  adopted_buckets = toset([
    "ossf-scorecard-cii-data",
    "ossf-scorecard-cron-results",
    "ossf-scorecard-data2",
    "ossf-scorecard-input-projects",
    "ossf-scorecard-rawdata",
    "ossf-scorecard-results",
  ])
}

resource "aws_s3_bucket_versioning" "adopted" {
  for_each = local.adopted_buckets

  bucket = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

# Versioning without expiry is an archive, not a safety net. cron-results takes
# ~2.66M overwrites a week (1.33M repos x results.json + raw.json) at roughly
# 16KB each, so unbounded retention adds ~40GB a week forever.
#
# Retention is counted in runs rather than days because the producer is weekly:
# newer_noncurrent_versions = 3 keeps the last three runs recoverable no matter
# how the schedule moves. noncurrent_days is not an alternative to that -- S3
# requires it alongside, as the minimum age before the count is enforced -- so
# 30 days is the floor and the count is the real bound.
#
# Verified 2026-09-06 that none of the six had any lifecycle configuration
# before this: aws_s3_bucket_lifecycle_configuration *replaces* whatever is on
# the bucket, so applying it blind would have silently dropped existing rules.
resource "aws_s3_bucket_lifecycle_configuration" "adopted" {
  for_each = local.adopted_buckets

  bucket = each.value

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      newer_noncurrent_versions = 3
      noncurrent_days           = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.adopted]
}

# --- Queue: SQS Standard + DLQ (E2), replacing GCP Pub/Sub -------------------

module "queue" {
  source = "../modules/queue"

  # Matches cron/config/config.yaml's existing Pub/Sub topic name. SQS has no
  # separate topic/subscription concept, so this one queue plays both roles
  # once group 6's URL-scheme subscriber/publisher selection lands.
  name = "scorecard-batch-requests"
  tags = local.tags
}

# --- Cluster: EKS, two node groups, Pod Identity (E1, E4) -------------------

module "cluster" {
  source = "../modules/cluster"

  name       = "scorecard-batch"
  subnet_ids = aws_subnet.private[*].id

  # Passed explicitly, not left to the module's own defaults, so
  # module.alerting's understaffed-node-group thresholds (below) cannot
  # silently drift from what this root actually asks the cluster to run.
  system_desired_size = var.system_desired_size
  worker_desired_size = var.worker_desired_size

  queue_arn                 = module.queue.queue_arn
  input_projects_bucket_arn = data.aws_s3_bucket.input_projects.arn
  test_bucket_arns          = { for k, b in aws_s3_bucket.test : k => b.arn }

  # Task 9.7. Constructed rather than read through data sources: an S3 bucket
  # ARN is fully determined by its name, and four lookups would buy nothing
  # over the local.adopted_buckets list these names already come from. Granted
  # in addition to the -test ARNs above, not instead -- see the module.
  production_bucket_arns = {
    cii_data     = "arn:aws:s3:::ossf-scorecard-cii-data"
    cron_results = "arn:aws:s3:::ossf-scorecard-cron-results"
    data2        = "arn:aws:s3:::ossf-scorecard-data2"
    rawdata      = "arn:aws:s3:::ossf-scorecard-rawdata"
  }

  secrets_read_policy_json = data.terraform_remote_state.cron_secrets.outputs.read_policy_json
  github_secret_arn        = data.terraform_remote_state.cron_secrets.outputs.secret_arns["github"]

  tags = local.tags
}

# --- Alerting: SNS + CloudWatch alarms on the DLQ, backlog age, and node
# groups (add-hosted-service-alerting) ---------------------------------------

module "alerting" {
  source = "../modules/alerting"

  name = "scorecard-batch"

  queue_name = module.queue.queue_name
  dlq_name   = module.queue.dlq_name

  system_asg_name     = module.cluster.system_node_group_asg_name
  worker_asg_name     = module.cluster.worker_node_group_asg_name
  system_desired_size = var.system_desired_size
  worker_desired_size = var.worker_desired_size

  alert_email_addresses = var.alert_email_addresses

  tags = local.tags
}

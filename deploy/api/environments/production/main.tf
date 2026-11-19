# Production: the origin the Fastly production backend points at, once staging
# has passed conformance.
#
# Identical in shape to staging by design. The cutover rehearsal only means
# something if the thing rehearsed is the thing performed, so the two roots
# differ in values and in exactly two behaviours: this one may WRITE to the
# results bucket, and it consumes the OIDC provider staging created rather than
# creating a second one.
#
# Apply staging first.

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
    key          = "api/production/terraform.tfstate"
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
  name = "scorecard-api-production"

  tags = {
    Project     = "scorecard"
    Component   = "api"
    Environment = "production"
    ManagedBy   = "opentofu"
    Source      = "ossf/scorecard-infra//deploy/api"
  }

  azs = var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Adopted, never managed (A13), and checked at plan time rather than at runtime.
data "aws_s3_bucket" "results" {
  bucket = var.results_bucket
}

data "aws_s3_bucket" "cron_results" {
  bucket = var.cron_results_bucket
}

module "network" {
  source = "../../modules/network"

  name               = local.name
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.azs
  tags               = local.tags
}

module "secrets" {
  source = "../../modules/secrets"

  name_prefix = "scorecard/production"
  tags        = local.tags
}

module "edge" {
  source = "../../modules/edge"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  origin_hostname   = var.origin_hostname
  tags              = local.tags
}

module "service" {
  source = "../../modules/service"

  name  = local.name
  image = var.image

  results_bucket      = data.aws_s3_bucket.results.bucket
  cron_results_bucket = data.aws_s3_bucket.cron_results.bucket
  api_base_url        = var.api_base_url

  # The only environment permitted to publish. Staging reads the same corpus and
  # must not be able to overwrite it.
  enable_publish_writes = true

  fastly_secret_arn        = module.secrets.secret_arns["fastly"]
  secrets_read_policy_json = module.secrets.read_policy_json

  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.edge.tasks_security_group_id
  target_group_arn   = module.edge.target_group_arn

  tags = local.tags
}

# --- Alerting: SNS + CloudWatch alarms on 5xx rate, unhealthy targets, and
# latency (add-hosted-service-alerting) --------------------------------------

module "alerting" {
  source = "../../modules/alerting"

  name = local.name

  alb_arn_suffix          = module.edge.alb_arn_suffix
  target_group_arn_suffix = module.edge.target_group_arn_suffix
  alert_email_addresses   = var.alert_email_addresses

  tags = local.tags
}

module "ci_oidc" {
  source = "../../modules/ci-oidc"

  name               = "${local.name}-deploy"
  github_repository  = var.github_repository
  github_environment = "production"

  # Staging created it; AWS permits one per issuer per account.
  create_oidc_provider       = false
  existing_oidc_provider_arn = var.oidc_provider_arn

  ecs_cluster_arn        = module.service.cluster_arn
  ecs_service_arn        = module.service.service_arn
  task_definition_family = module.service.task_definition_family

  passable_role_arns = [
    module.service.task_role_arn,
    module.service.execution_role_arn,
  ]

  tags = local.tags
}

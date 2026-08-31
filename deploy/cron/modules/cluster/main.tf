# The EKS cluster and node groups (E1). Scaffolding only -- resources land in
# provision-cron-aws group 5. See openspec/changes/provision-cron-aws/tasks.md.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

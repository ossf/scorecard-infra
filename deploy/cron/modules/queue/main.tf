# The SQS Standard queue and DLQ (E2). Scaffolding only -- resources land in
# provision-cron-aws group 4. See openspec/changes/provision-cron-aws/tasks.md.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

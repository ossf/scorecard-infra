# SQS Standard queue + DLQ (E2), replacing GCP Pub/Sub's topic/subscription
# pair. SQS has no separate topic/subscription concept -- once group 6 (the
# subscriber_sqs.go rework) and group 7.2 (the AWS config overlay) land,
# cron/config/config.yaml's request-topic-url and request-subscription-url
# both point at this one queue, publish and consume against the same
# resource.
#
# visibility_timeout_seconds and receive_wait_time_seconds default to the
# values found on the pre-existing, never-adopted openssf-scorecard queue
# (E8): whoever tuned it on 2026-08-28 understood this workload -- a long
# visibility window because a scan can run long, maximum long-polling
# because workers poll continuously -- even though that queue itself was not
# reused. These are starting values the heartbeat (E3, group 6) extends, not
# the sole protection against redelivery.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_sqs_queue" "dlq" {
  name = "${var.name}-dlq"

  tags = var.tags
}

resource "aws_sqs_queue" "this" {
  name = var.name

  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

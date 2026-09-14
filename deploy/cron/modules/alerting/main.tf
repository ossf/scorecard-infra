# CloudWatch alarms for the batch plane, fanned out through one SNS topic.
#
# Exists because the plane's first production run (2026-09-09) silently lost
# 529 messages to the DLQ in its last 45 minutes -- the three manual health
# checks running at the time (pod status, Warning events, purge failures) all
# stayed green, because none of them looks at queue depth. The alarms below
# are the automated replacement for that blind spot, not an exhaustive health
# model: pod-level restart/OOMKill alerting and a shard-count census are
# deliberately out of scope (see this change's design.md) and are follow-up
# changes of their own.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
  tags = var.tags
}

# Confirmation is manual and out-of-band (each address gets a "Subscription
# Confirmation" email to accept), the same out-of-band posture this repo
# already takes with secret values -- the address is a name in the state file
# either way, so a Terraform-issued subscription is no worse, but the
# confirmation step cannot be automated from here.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_addresses)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# The exact signal that would have caught the 529-message loss within
# minutes: a non-empty DLQ means messages have already exhausted their
# retries and been dropped from the working queue, so this fires at the
# lowest possible threshold rather than waiting for a "meaningful" backlog.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-dlq-not-empty"
  alarm_description   = "The batch plane's dead-letter queue has received a message -- shards are being lost, not just delayed."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dlq_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  # A DLQ with no messages simply reports no datapoints rather than a zero,
  # so "missing" here means "empty", not "unknown" -- the opposite of what
  # treat_missing_data usually guards against.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# Backstops the DLQ alarm against a run that stalls without any message
# failing outright -- e.g. a worker deadlock -- which would leave the DLQ
# empty while the corpus goes unscanned. Thresholded well above the observed
# 60h15m first-run baseline, inside the weekly 7-day cadence's margin, so it
# fires on a stall rather than on ordinary run-length variance.
resource "aws_cloudwatch_metric_alarm" "queue_backlog_age" {
  alarm_name          = "${var.name}-queue-backlog-age"
  alarm_description   = "The oldest unprocessed shard has been waiting longer than a full run should take -- the batch plane may be stalled."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 2
  threshold           = var.backlog_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# AWS/AutoScaling's GroupInServiceInstances is a zero-new-infrastructure proxy
# for node health: this cluster runs no CloudWatch agent (no Container
# Insights, no metrics-server), so pod-level signals are out of reach today,
# but the ASG behind each node group already publishes this for free.
resource "aws_cloudwatch_metric_alarm" "system_node_group_understaffed" {
  alarm_name          = "${var.name}-system-node-group-understaffed"
  alarm_description   = "The system node group (controller, token server) has fewer in-service instances than desired."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = var.system_asg_name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.system_desired_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "worker_node_group_understaffed" {
  alarm_name          = "${var.name}-worker-node-group-understaffed"
  alarm_description   = "The worker node group (scan capacity) has fewer in-service instances than desired."
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  dimensions          = { AutoScalingGroupName = var.worker_asg_name }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.worker_desired_size
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

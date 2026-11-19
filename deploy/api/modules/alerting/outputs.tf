output "topic_arn" {
  description = "The serving plane's alert SNS topic, in case another root ever needs to subscribe something other than email to it."
  value       = aws_sns_topic.alerts.arn
}

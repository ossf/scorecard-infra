output "queue_url" {
  description = "For the awssqs:// request-topic-url/request-subscription-url once group 6/7.2 land."
  value       = aws_sqs_queue.this.url
}

output "queue_arn" {
  description = "For the worker/controller Pod Identity roles' IAM policies (group 5.4)."
  value       = aws_sqs_queue.this.arn
}

output "dlq_url" {
  description = "For task 9.5's verification -- confirming a permanently-failing message lands here."
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = <<-EOT
    For task 5.6's explicit-denial verification: the worker role needs no
    DLQ access, so confirm it is refused, not just that its own queue grant
    works.
  EOT
  value       = aws_sqs_queue.dlq.arn
}

output "private_subnet_ids" {
  description = "Batch cluster subnets. EKS's node groups and control plane ENIs go here (group 5)."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "For anything group 4-5 needs to reference by route table, e.g. VPC endpoint associations added later."
  value       = aws_route_table.private[*].id
}

output "test_bucket_arns" {
  description = "Keyed the same as var.test_buckets, for the IAM policies group 5.4 scopes to exactly these buckets."
  value       = { for k, b in aws_s3_bucket.test : k => b.arn }
}

output "test_bucket_names" {
  description = "Keyed the same as var.test_buckets, for the config overlay group 7.2 writes."
  value       = { for k, b in aws_s3_bucket.test : k => b.bucket }
}

output "queue_url" {
  description = "For the awssqs:// request-topic-url/request-subscription-url once group 6/7.2 land."
  value       = module.queue.queue_url
}

output "queue_arn" {
  description = "For the worker/controller Pod Identity roles' IAM policies (group 5.4)."
  value       = module.queue.queue_arn
}

output "dlq_url" {
  description = "For task 9.5's verification -- confirming a permanently-failing message lands here."
  value       = module.queue.dlq_url
}

output "dlq_arn" {
  description = "For task 5.6's explicit-denial verification -- the worker role should be refused access to this."
  value       = module.queue.dlq_arn
}

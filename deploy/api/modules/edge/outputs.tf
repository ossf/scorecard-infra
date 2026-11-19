output "certificate_validation_records" {
  description = <<-EOT
    DNS records to create in Netlify by hand, before the apply can finish.
    Available as soon as the certificate resource exists, which is why the
    first run targets that resource alone.
  EOT
  value = [
    for o in aws_acm_certificate.this.domain_validation_options : {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}

output "alb_dns_name" {
  description = <<-EOT
    Point origin_hostname's CNAME at this, in Netlify. Then point the Fastly
    backend at origin_hostname -- not at this name, which is AWS-generated and
    tied to this load balancer's identity rather than to the service.
  EOT
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the load balancer, for an alias record if DNS ever moves to Route 53."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "Target group the ECS service registers its tasks into."
  value       = aws_lb_target_group.this.arn
}

output "tasks_security_group_id" {
  description = "Security group for the tasks. Ingress from the load balancer only."
  value       = aws_security_group.tasks.id
}

output "https_listener_arn" {
  description = "HTTPS listener ARN."
  value       = aws_lb_listener.https.arn
}

output "alb_arn_suffix" {
  description = <<-EOT
    CloudWatch's AWS/ApplicationELB dimensions take this short form
    (app/name/id), not the full ARN already exposed above -- for the
    alerting module's per-load-balancer metrics.
  EOT
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  description = "Same shape as alb_arn_suffix, for per-target-group metrics."
  value       = aws_lb_target_group.this.arn_suffix
}

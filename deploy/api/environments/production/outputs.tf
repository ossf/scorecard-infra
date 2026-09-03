output "certificate_validation_records" {
  description = "Create in Netlify DNS; the apply blocks until they resolve."
  value       = module.edge.certificate_validation_records
}

output "alb_dns_name" {
  description = <<-EOT
    Point origin_hostname's CNAME at this in Netlify.

    Do NOT put this name in the Fastly backend. Point Fastly at
    origin_hostname, so replacing the load balancer later is a DNS change rather
    than a production cutover.
  EOT
  value       = module.edge.alb_dns_name
}

output "origin_hostname" {
  description = <<-EOT
    The cutover: set the Fastly production backend to this. Rollback is
    restoring the previous value, which is why the old origin should not be
    decommissioned until the hold period ends.
  EOT
  value       = var.origin_hostname
}

output "nat_egress_ips" {
  description = "Stable outbound addresses, should GitHub or GitLab ever need an allowlist."
  value       = module.network.nat_public_ips
}

output "vpc_id" {
  description = <<-EOT
    Read by provision-cron-aws's deploy/cron/production via terraform_remote_state
    (E5) -- the batch plane shares this VPC rather than provisioning its own.
  EOT
  value       = module.network.vpc_id
}

output "nat_gateway_ids" {
  description = "Read by deploy/cron/production (E5) to route its private subnets through the existing NAT Gateway."
  value       = module.network.nat_gateway_ids
}

output "s3_endpoint_id" {
  description = "Read by deploy/cron/production (E5) to associate its own route tables with this VPC's single S3 gateway endpoint."
  value       = module.network.s3_endpoint_id
}

output "availability_zones" {
  description = <<-EOT
    Read by deploy/cron/production (E5) so its subnets land in the same AZs
    this root actually resolved to, rather than recomputing
    aws_availability_zones and risking the two roots picking different zones.
  EOT
  value       = local.azs
}

output "deploy_role_arn" {
  description = "For the workflow's configure-aws-credentials step."
  value       = module.ci_oidc.role_arn
}

output "log_group_name" {
  description = "Where the container logs land."
  value       = module.service.log_group_name
}

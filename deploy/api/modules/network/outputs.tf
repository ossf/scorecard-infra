output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnets. The load balancer goes here; nothing else should."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets. The tasks go here, with no public IP."
  value       = aws_subnet.private[*].id
}

output "nat_public_ips" {
  description = <<-EOT
    Egress addresses. Stable, because they are Elastic IPs -- which matters if
    GitHub or GitLab ever need an allowlist, and is why NAT is used rather than
    public IPs on the tasks.
  EOT
  value       = aws_eip.nat[*].public_ip
}

output "s3_endpoint_id" {
  description = "S3 gateway endpoint. Object reads take this path, not NAT."
  value       = aws_vpc_endpoint.s3.id
}

output "nat_gateway_ids" {
  description = <<-EOT
    NAT Gateway resource IDs, for a route table outside this module to route
    0.0.0.0/0 through the same gateway rather than provisioning a new one --
    e.g. provision-cron-aws's batch plane, which shares this VPC (E5).
  EOT
  value       = aws_nat_gateway.this[*].id
}

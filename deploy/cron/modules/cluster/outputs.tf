output "cluster_name" {
  description = "For group 8's `aws eks update-kubeconfig` step."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "For group 8's CI workflow, if it needs the API endpoint directly rather than resolving it via update-kubeconfig."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "For group 8's CI workflow, same reason as cluster_endpoint."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "controller_service_account" {
  description = "Group 7.1 must set this as controller.yaml's serviceAccountName -- see this module's header comment."
  value       = var.controller_service_account
}

output "worker_service_account" {
  description = "Group 7.1 must set this as worker.yaml's serviceAccountName."
  value       = var.worker_service_account
}

output "cii_service_account" {
  description = "Group 7.1 must set this as cii.yaml's serviceAccountName."
  value       = var.cii_service_account
}

output "github_server_service_account" {
  description = "Group 7.1 must set this as auth.yaml's serviceAccountName."
  value       = var.github_server_service_account
}

output "node_pool_label" {
  description = <<-EOT
    The node label both pools carry, and the taint key the worker pool
    carries. Group 7.1 needs it for worker.yaml's toleration and for every
    workload's nodeSelector.
  EOT
  value = {
    key          = local.pool_key
    system_value = "system"
    worker_value = "worker"
    worker_taint = "${local.pool_key}=worker:NoSchedule"
  }
}

output "namespace" {
  description = "The namespace every ServiceAccount above, and its Pod Identity association, is created in."
  value       = var.namespace
}

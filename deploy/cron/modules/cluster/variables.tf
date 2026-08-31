variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes version. Not pinned by design.md -- confirm against AWS's
    currently-supported EKS versions before applying. A starting pin, not a
    considered-forever choice; upgrade cadence is out of scope for this
    change.
  EOT
  type        = string
  default     = "1.31"
}

variable "subnet_ids" {
  description = <<-EOT
    Private subnets from deploy/cron/production's own network resources
    (group 3, task 3.1's shared-VPC decision). Control plane ENIs and both
    node groups land here -- no public IP anywhere in the data plane.
  EOT
  type        = list(string)
}

variable "namespace" {
  description = <<-EOT
    Kubernetes namespace every workload and its Pod Identity association
    runs in. No cron/k8s/*.yaml manifest sets one explicitly today, so this
    defaults to the implied "default" namespace group 7 inherits.
  EOT
  type        = string
  default     = "default"
}

variable "controller_service_account" {
  description = <<-EOT
    Group 7 (task 7.1) MUST add this as an explicit serviceAccountName to
    controller.yaml -- see this module's header comment for why a shared
    "default" ServiceAccount across three workloads cannot work under Pod
    Identity.
  EOT
  type        = string
  default     = "scorecard-batch-controller"
}

variable "worker_service_account" {
  description = "See controller_service_account -- same requirement, worker.yaml."
  type        = string
  default     = "scorecard-batch-worker"
}

variable "github_server_service_account" {
  description = "See controller_service_account -- same requirement, auth.yaml."
  type        = string
  default     = "scorecard-github-server"
}

variable "system_instance_type" {
  description = <<-EOT
    Starting guess for the system pool: the controller CronJob (bursts to
    one pod weekly, 1Gi memory limit per controller.yaml) and github-server
    (currently 0 replicas in cron/k8s/auth.yaml) need little. Tune after
    verification (A8), not a considered-forever choice.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "system_min_size" {
  type    = number
  default = 1
}

variable "system_max_size" {
  type    = number
  default = 2
}

variable "system_desired_size" {
  type    = number
  default = 1
}

variable "worker_instance_type" {
  description = <<-EOT
    Starting guess for the worker pool. cron/k8s/worker.yaml sets no
    resources.requests/limits, so there is no hard sizing signal in the
    manifest itself to size against. A defensible starting point (A8), not
    a considered-forever choice.
  EOT
  type        = string
  default     = "m5.large"
}

variable "worker_min_size" {
  type    = number
  default = 2
}

variable "worker_max_size" {
  type    = number
  default = 6
}

variable "worker_desired_size" {
  description = <<-EOT
    Node count, not pod count. E1's 14-worker baseline is
    cron/k8s/worker.yaml's Deployment replica count, unrelated to this
    module -- this is how many nodes host those 14 pods.
  EOT
  type        = number
  default     = 3
}

variable "queue_arn" {
  description = "The main queue (group 4) -- controller publishes, worker consumes. Neither role is granted the DLQ (E2/task 5.6: denial to the DLQ is a feature, not a gap)."
  type        = string
}

variable "input_projects_bucket_arn" {
  description = <<-EOT
    The adopted, read-only ossf-scorecard-input-projects bucket (E6/E7) --
    no test counterpart, per design.md's own reasoning: the controller only
    ever reads it, so testing against the real one carries no write risk.
  EOT
  type        = string
}

variable "test_bucket_arns" {
  description = <<-EOT
    Keyed cron_results/data2/rawdata, matching deploy/cron/production's own
    var.test_buckets. The six adopted production buckets are deliberately
    absent from every policy this module writes -- task 5.6 verifies that
    absence as denial, not an oversight to fix here. Widening to production
    buckets is task 9.7's job, once verification against these passes.
  EOT
  type        = map(string)
}

variable "secrets_read_policy_json" {
  description = <<-EOT
    deploy/cron/secrets' combined github+gitlab read policy
    (terraform_remote_state against cron/secrets/terraform.tfstate).
    Attached to controller and worker only, per design.md task 5.4 --
    github-server gets github_secret_arn below instead, scoped narrower.
  EOT
  type        = string
}

variable "github_secret_arn" {
  description = "Scoped to exactly the github secret -- github-server has no business reading the gitlab credential the way controller/worker's combined policy does."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

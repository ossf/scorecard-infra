variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes version. 1.36 is the newest version on EKS standard support as
    of 2026-08-31, and newest is the deliberate choice: it buys the longest
    runway before the next forced upgrade, and it keeps the cluster off
    extended support, which prices a control plane at roughly six times the
    standard rate. An earlier draft pinned 1.31, whose standard support ended
    in 2025 -- that would have cost more per month than the second NAT Gateway
    E5 declined to buy. Upgrade cadence itself is out of scope for this change.
  EOT
  type        = string
  default     = "1.36"
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

# --- Cluster endpoint and logging -------------------------------------------

variable "endpoint_private_access" {
  description = <<-EOT
    Keeps node-to-API-server traffic inside the VPC instead of routing it out
    through the NAT Gateway this plane shares with the serving plane (E5),
    where it would be billed as data processing.
  EOT
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = <<-EOT
    Group 8's deploy workflow runs on GitHub-hosted runners and reaches the
    API server from outside the VPC. Turning this off requires moving CI onto
    self-hosted runners in-VPC first.
  EOT
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = <<-EOT
    Left open deliberately, not by omission: GitHub-hosted runners have no
    stable egress range worth allowlisting, so IAM and EKS access entries are
    the access control here, not the network. Narrow this the moment CI has a
    fixed egress address.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    Control-plane logs, off by default in EKS. These three answer "who called
    the API server and were they allowed to" -- worth having on a cluster that
    holds the corpus's write credentials. Scheduler and controller-manager
    logs are debugging aids with no standing need here.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch retention for the control-plane log group. Finite on purpose,
    matching deploy/api/modules/service: EKS's own default is "never expire",
    which is a slow cost leak rather than a durability feature.
  EOT
  type        = number
  default     = 30
}

# --- ServiceAccounts (group 7.1 must create these in the manifests) ---------

variable "controller_service_account" {
  description = <<-EOT
    Group 7 (task 7.1) MUST add this as an explicit serviceAccountName to
    controller.yaml -- see this module's header comment for why a shared
    "default" ServiceAccount across four workloads cannot work under Pod
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

variable "cii_service_account" {
  description = "See controller_service_account -- same requirement, cii.yaml."
  type        = string
  default     = "scorecard-cii-worker"
}

variable "github_server_service_account" {
  description = "See controller_service_account -- same requirement, auth.yaml."
  type        = string
  default     = "scorecard-github-server"
}

# --- Node groups ------------------------------------------------------------

variable "system_instance_type" {
  description = <<-EOT
    The system pool runs CoreDNS, the controller CronJob (bursts to one pod
    weekly, 1Gi memory limit per controller.yaml) and github-server
    (currently replicas: 0 in cron/k8s/auth.yaml). Tune after verification
    (A8), not a considered-forever choice.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "system_min_size" {
  description = "Two, not one: CoreDNS runs two replicas and wants two nodes to spread across."
  type        = number
  default     = 2
}

variable "system_max_size" {
  type    = number
  default = 3
}

variable "system_desired_size" {
  type    = number
  default = 2
}

variable "system_disk_size" {
  description = "GiB. EKS's own default; the system pool holds no working data."
  type        = number
  default     = 20
}

variable "worker_instance_type" {
  description = <<-EOT
    cron/k8s/worker.yaml sets no resources.requests/limits, so there is no
    hard sizing signal in the manifest to size against -- but the pods do real
    work (cloning and analysing repositories), so the provider default of
    "whatever fits" is not a defensible starting point either. m5.xlarge at
    the counts below gives each of the 14 worker pods roughly one vCPU and
    4 GiB. This is the single largest cost lever in the whole plane; revisit
    it against real utilisation after group 9, per A8.
  EOT
  type        = string
  default     = "m5.xlarge"
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

variable "worker_disk_size" {
  description = <<-EOT
    GiB, and larger than EKS's 20 GiB default on purpose: worker pods clone
    repositories to local disk, several to a node, and a full ephemeral-
    storage volume evicts pods rather than failing one scan. Cheap insurance
    at gp3 prices.
  EOT
  type        = number
  default     = 100
}

# --- Wiring from deploy/cron/production -------------------------------------

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
    Keyed cron_results/data2/rawdata/cii_data, matching deploy/cron/production's
    own var.test_buckets. Not every role gets every bucket: the worker gets
    the first three, the CII worker gets only cii_data, the controller only
    data2. The six adopted production buckets are deliberately absent from
    every policy this module writes -- task 5.6 verifies that absence as
    denial, not an oversight to fix here. Widening to production buckets is
    task 9.7's job, once verification against these passes.
  EOT
  type        = map(string)

  validation {
    condition     = length(setsubtract(["cron_results", "data2", "rawdata", "cii_data"], keys(var.test_bucket_arns))) == 0
    error_message = "test_bucket_arns must contain cron_results, data2, rawdata and cii_data -- each names a bucket some role below is scoped to."
  }
}

variable "secrets_read_policy_json" {
  description = <<-EOT
    deploy/cron/secrets' combined github+gitlab+fastly read policy
    (terraform_remote_state against cron/secrets/terraform.tfstate). Attached
    to the worker alone: it is the only workload that reads a credential from
    more than one secret. The controller reads none (no os.Getenv in
    cron/internal/controller/), the CII worker reads none, and github-server
    gets github_secret_arn below instead, scoped narrower.
  EOT
  type        = string
}

variable "github_secret_arn" {
  description = "Scoped to exactly the github secret -- github-server has no business reading the gitlab or fastly credentials the way the worker's combined policy does."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

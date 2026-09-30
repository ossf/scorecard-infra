variable "region" {
  description = "Observed from where the corpus buckets are, not chosen (A5)."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = <<-EOT
    Distinct from staging's default so the two never collide if they are ever
    peered or share a transit gateway.
  EOT
  type        = string
  default     = "10.21.0.0/16"
}

variable "availability_zones" {
  description = "Override the AZs. Null picks the first two available."
  type        = list(string)
  default     = null
}

variable "image" {
  description = <<-EOT
    Container image pinned by digest, from an `api/v*` release tag resolved to a
    digest. Never the tag itself: a rollback has to name a known build rather
    than whatever the tag means at the moment it is re-read.
  EOT
  type        = string
}

variable "origin_hostname" {
  description = <<-EOT
    Hostname the Fastly PRODUCTION backend will point at, e.g.
    origin.scorecard.dev.

    No default. This is not api.scorecard.dev -- that is the published CDN
    hostname. This is the origin behind Fastly, a new record in Netlify DNS, and
    changing the Fastly backend to it is the cutover itself.
  EOT
  type        = string
}

variable "api_base_url" {
  description = <<-EOT
    Captured from the running Cloud Run service, so this is the value in effect
    today rather than an assumption. It is what the API purges against after a
    publish.

    Note the pre-existing defect it participates in: api.scorecard.dev and
    api.securityscorecards.dev cache separately under a year-long
    Surrogate-Control, and only this one is purged. That is not introduced by
    the migration and is not fixed by it.
  EOT
  type        = string
  default     = "https://api.scorecard.dev"
}

variable "results_bucket" {
  description = "Primary results bucket. Read and written here; read-only in staging."
  type        = string
  default     = "ossf-scorecard-results"
}

variable "cron_results_bucket" {
  description = "Fallback results bucket. Read-only."
  type        = string
  default     = "ossf-scorecard-cron-results"
}

variable "github_repository" {
  description = "The one repository allowed to deploy, as owner/name."
  type        = string
  default     = "ossf/scorecard-infra"
}

variable "oidc_provider_arn" {
  description = <<-EOT
    The GitHub OIDC provider created by the staging root. AWS permits one per
    issuer per account, so this root consumes rather than creates it -- take the
    value from staging's oidc_provider_arn output.
  EOT
  type        = string
}

variable "alert_email_addresses" {
  description = <<-EOT
    Addresses subscribed to the serving plane's alert SNS topic
    (add-hosted-service-alerting). No default -- an account-specific value,
    like origin_hostname above. Supply with -var or an untracked *.tfvars
    file (see .gitignore's *.tfvars entry). Not declared in the staging
    root: staging carries no on-call expectation.
  EOT
  type        = list(string)
}

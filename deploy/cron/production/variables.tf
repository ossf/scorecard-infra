variable "region" {
  description = "Same account and region as the serving plane and the corpus buckets (A5)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket" {
  description = <<-EOT
    The OpenTofu state bucket, same one this root's own backend block is
    initialized against (tofu init -backend-config=bucket=...). Passed again
    here because the terraform_remote_state data source's config cannot be
    supplied via -backend-config; only the root's own backend block gets
    partial configuration.
  EOT
  type        = string
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    /20s carved out of scorecard-api-production's 10.21.0.0/16, chosen
    (design.md, E5) to extend the private range without colliding with the
    four subnets deploy/api already created: 10.21.0.0 and 10.21.16.0
    (public), 10.21.128.0 and 10.21.144.0 (private).
  EOT
  type        = list(string)
  default     = ["10.21.160.0/20", "10.21.176.0/20"]
}

variable "test_buckets" {
  description = <<-EOT
    Test buckets (E7), keyed by the cron/config/config.yaml field each
    corresponds to. Named after their production counterparts with a -test
    suffix so a bucket list is self-explanatory without a lookup table.
  EOT
  type        = map(string)
  default = {
    cron_results = "ossf-scorecard-cron-results-test"
    data2        = "ossf-scorecard-data2-test"
    rawdata      = "ossf-scorecard-rawdata-test"
  }
}

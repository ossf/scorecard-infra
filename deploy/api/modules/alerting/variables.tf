variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
}

variable "alb_arn_suffix" {
  description = "From module.edge.alb_arn_suffix."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "From module.edge.target_group_arn_suffix."
  type        = string
}

variable "alert_email_addresses" {
  description = <<-EOT
    Addresses to subscribe to this plane's SNS topic. No default -- same
    reasoning as deploy/cron/modules/alerting's variable of the same name.
  EOT
  type        = list(string)
}

variable "target_5xx_threshold" {
  description = "Alarm fires once target-origin 5xx responses in a 5-minute window exceed this count."
  type        = number
  default     = 5
}

variable "latency_p90_threshold_seconds" {
  description = "Alarm fires once p90 target response time exceeds this many seconds for three consecutive 5-minute periods."
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

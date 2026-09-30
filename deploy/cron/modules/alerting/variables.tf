variable "name" {
  description = "Name prefix for every resource this module creates."
  type        = string
}

variable "queue_name" {
  description = "Main queue's CloudWatch QueueName dimension, from module.queue.queue_name."
  type        = string
}

variable "dlq_name" {
  description = "DLQ's CloudWatch QueueName dimension, from module.queue.dlq_name."
  type        = string
}

variable "system_asg_name" {
  description = "System node group's Auto Scaling group name, from module.cluster.system_node_group_asg_name."
  type        = string
}

variable "worker_asg_name" {
  description = "Worker node group's Auto Scaling group name, from module.cluster.worker_node_group_asg_name."
  type        = string
}

variable "system_desired_size" {
  description = "Same value passed to module.cluster -- the threshold the understaffed alarm compares against."
  type        = number
}

variable "worker_desired_size" {
  description = "Same value passed to module.cluster -- the threshold the understaffed alarm compares against."
  type        = number
}

variable "alert_email_addresses" {
  description = <<-EOT
    Addresses to subscribe to this plane's SNS topic. No default -- like
    var.origin_hostname in deploy/api, this is an account-specific value with
    no sensible default this module could assume. Each address receives a
    one-time SNS subscription-confirmation email that must be accepted by
    hand before alarms reach it.
  EOT
  type        = list(string)
}

variable "backlog_age_threshold_seconds" {
  description = <<-EOT
    Alarm threshold for the oldest unprocessed message's age. Defaults to
    290400 (80.67 hours): comfortably above the first production run's
    observed 60h15m completion time, while still leaving most of the weekly
    (604800s) cadence's ~4.5-day margin before the next scheduled run.
  EOT
  type        = number
  default     = 290400
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

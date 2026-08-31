variable "name" {
  description = "Queue name. No default -- this module has no sensible name of its own to assume."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = <<-EOT
    Starting value the heartbeat (E3, group 6) extends before this expires,
    not the sole protection against redelivery. Defaults to 3600, carried
    from the pre-existing, never-adopted openssf-scorecard queue's tuning
    (E8) -- whoever set it understood a scan can run long.
  EOT
  type        = number
  default     = 3600
}

variable "receive_wait_time_seconds" {
  description = "Long polling. Defaults to 20 (the maximum), carried from E8's tuning -- workers poll continuously."
  type        = number
  default     = 20
}

variable "max_receive_count" {
  description = <<-EOT
    Deliveries before a message moves to the DLQ instead of retrying
    forever. E8's placeholder queue never had this set (its RedrivePolicy
    was submitted empty on every call); this is a fresh choice, not a
    carried-over value.
  EOT
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

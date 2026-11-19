# Proposal: CloudWatch alerting for both AWS planes

## Why

Neither AWS plane has any automated alerting. Every `.tf` file under
`deploy/` was zero `aws_cloudwatch_metric_alarm` and zero `aws_sns_*`
resources before this change; health is checked by hand.

That gap is not theoretical. The batch plane's first production run
(completed 2026-09-09) silently lost 529 messages — about 5,290 repositories,
0.40% of the corpus — to its dead-letter queue in the run's last 45 minutes.
The three manual health checks running at the time (pod status, Kubernetes
Warning events, CDN purge-failure count) all stayed green throughout, because
none of them looks at queue depth. The gap was flagged explicitly at the
time: queue depth alone cannot see this, and nothing was watching it.

The serving plane (`api/` on ECS/ALB) has the same absence of alarms, just no
incident yet to prove it.

## What Changes

- **Add `deploy/cron/modules/alerting`**: an SNS topic plus CloudWatch alarms
  on the batch plane's dead-letter queue depth, main-queue backlog age, and
  each EKS node group's in-service instance count.
- **Add `deploy/api/modules/alerting`**: an SNS topic plus CloudWatch alarms
  on the serving plane's ALB target 5xx rate, unhealthy target count, and
  p90 target response time.
- **One SNS topic per plane, not one shared topic** — the two planes are
  already deployed independently (`aws-serving` spec, "plane independence"),
  and a shared alert topic would introduce a coupling this change has no
  reason to add.
- **Email is the only notification channel.** Each topic subscribes the
  addresses in a new `alert_email_addresses` variable, required with no
  default on both production roots (matching the existing pattern for
  account-specific values like `origin_hostname`). Not declared on the
  staging API root — staging carries no on-call expectation.
- Small output additions to two existing modules so the alerting modules can
  reference the right CloudWatch dimensions without new data sources:
  `deploy/cron/modules/cluster` gains each node group's Auto Scaling group
  name, and `deploy/api/modules/edge` gains the ALB's and target group's ARN
  suffixes.

**Deliberately out of scope**, each a follow-up change of its own (this
repo's convention for deferred work — see `AGENTS.md`'s "Quarantined: do not
'fix' these"):

- **Pod-level restart/OOMKill alerting on the batch plane's EKS cluster.**
  That needs Container Insights or an equivalent CloudWatch-agent DaemonSet;
  this cluster runs neither today (it has no metrics-server at all), and
  adding one is its own infrastructure decision, not a byproduct of wiring up
  alarms on metrics that already exist for free.
- **A shard-count / census reconciliation check.** Comparing shards written
  against `numShard` in `.shard_metadata` is what would have caught the
  529-message loss fastest, but it is an application-level fact with no
  native CloudWatch metric — it needs a custom-metric publisher, which is
  meaningfully more scope than wiring alarms onto metrics AWS already emits.

## Capabilities

### New Capabilities

- `operational-alerting`: CloudWatch alarms on each plane's own SNS topic,
  covering the batch plane's dead-letter queue, backlog age, and node-group
  health, and the serving plane's error rate, target health, and latency;
  each topic notifies a human by email.

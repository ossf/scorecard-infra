# Design: CloudWatch alerting for both AWS planes

Decision tags **G1**-**G8**. They are referenced from `tasks.md` and should be
cited in commit bodies, following the convention the other changes use.
(A/C/D/F is `provision-aws`/`configure-result-buckets`; E is
`provision-cron-aws`; the rest belong to other changes not touched here.)

## G1: One SNS topic per plane, not one shared topic

The batch and serving planes are already required to deploy independently
(`aws-serving` spec, "The serving and batch planes are deployed
independently"): separate roots, separate state, separate identities, neither
depending on compute the other operates. A single shared alert topic would
not violate that requirement's letter — SNS is not compute either plane
depends on to do its job — but it would mean a change to one plane's root
(adding a subscriber, tightening a topic policy) touches a resource the other
plane's alarms also point at. Two topics keep the alerting change inside
each plane's own root, same as everything else about it.

## G2: DLQ depth threshold is `> 0`, not a "meaningful backlog" count

The batch plane's dead-letter queue existing at all means messages have
already exhausted `max_receive_count` retries and been dropped from the
working queue — by the time a message is in the DLQ, work has already been
lost, not merely delayed. There is no threshold above zero that is "still
fine": the 529-message incident was invisible specifically because nothing
was watching for the *first* message to land, and by the time someone looked,
it was 529. `treat_missing_data = "notBreaching"` on this alarm is not a
gap in reverse: an empty DLQ publishes no CloudWatch datapoint, and "no
datapoint" here is the healthy state, not an unknown one.

## G3: Queue backlog age threshold (290,400s / 80.67h)

Backstops G2 against a stall that never produces a DLQ message at all — a
worker deadlock, for instance, would leave the DLQ empty while the corpus
goes unscanned. The threshold sits above the first production run's observed
60h15m completion time (with margin for run-to-run variance) and comfortably
inside the weekly (604,800s) cadence's ~4.5-day margin, so it fires on an
actual stall rather than on ordinary run-length variance. Revisit once more
than one production run's timing exists to compare against — this is a
one-data-point estimate, stated as such.

## G4: Node-group health via `AWS/AutoScaling`, not Container Insights

`GroupInServiceInstances` on the Auto Scaling group behind each EKS node
group is published for free, with no agent, DaemonSet, or additional cost —
unlike pod-level signals (restarts, OOMKill), which need Container Insights
or an equivalent CloudWatch-agent DaemonSet that this cluster does not run
today (it has no metrics-server at all; see the batch-plane operational
history). This alarm catches "a node group can't hold its desired capacity"
(capacity/AZ/quota problems), which is a real and cheap signal to have — it
does **not** catch a pod crash-looping on an otherwise-healthy node. That gap
is intentional for this change; closing it is Container Insights's own
follow-up change, not a rider on this one.

## G5: Serving-plane alarm selection

Three alarms, chosen to cover availability and latency without adding new
instrumentation, since `deploy/api/modules/service` already runs Container
Insights on its ECS cluster and the ALB already publishes standard
`AWS/ApplicationELB` metrics:

- **Target 5xx count**, not ELB 5xx count: a target-origin error is the API's
  own failure; an ELB-origin error is more often a client or edge condition
  the API never saw. `Sum` over a 5-minute window, not `Average` — a handful
  of 5xxs in a low-traffic period should still page, and averaging against
  request volume would mask exactly that case.
- **Unhealthy target count `> 0`** for three consecutive 1-minute periods —
  the ALB's own health check already has a 3-strike `unhealthy_threshold`
  (`deploy/api/modules/edge`), so this alarm's own evaluation window adds a
  second, independent confirmation rather than paging on the ALB's first
  failed probe.
- **p90 target response time**, not p99 or average: p99 on a two-task
  service is noisy enough to false-positive on ordinary GC pauses; average
  hides a slow tail entirely. p90 is the smallest percentile that still means
  "most requests," which is what a paging alarm should represent.

## G6: Email via SNS, confirmed out-of-band

Each `aws_sns_topic_subscription` with `protocol = "email"` requires the
subscriber to click a one-time confirmation link AWS sends directly — nothing
in this change's OpenTofu can complete that step. This is the same posture
`infrastructure-as-code`'s secret-value requirement already takes with
secrets: the container is declared here, the human step happens out-of-band.
The address itself is not a secret value (SNS states are not exempted from
that requirement, and an email address is not one), so it is passed as an
ordinary variable rather than loaded through Secrets Manager.

## G7: Deferred — pod/OOMKill alerting and shard census

Recorded in `proposal.md`'s "Deliberately out of scope." Both are real gaps
this change does not close: **G4** already states what the node-group alarms
cannot see, and a shard-count census — comparing shards written against
`numShard` in `.shard_metadata` — is the single check that would have caught
the 529-message loss fastest, since it directly measures the invariant that
broke. Neither is a natural extension of "add alarms on metrics AWS already
publishes," which is this change's actual scope; both need their own design
work (an agent/DaemonSet decision for the first, a custom-metric publisher
for the second).

## G8: Production only, not staging

`alert_email_addresses` is declared only on `deploy/cron/production` and
`deploy/api/environments/production`, not on
`deploy/api/environments/staging`. Staging carries no on-call expectation —
its own conformance suite is the signal that matters there, not a page.

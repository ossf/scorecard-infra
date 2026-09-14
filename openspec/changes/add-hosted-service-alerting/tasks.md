# Tasks: CloudWatch alerting for both AWS planes

Decision tags **G1**-**G8** are defined in `design.md`.

## 1. Discovery

- [x] 1.1 Confirm no CloudWatch alarms or SNS topics exist anywhere under
      `deploy/` today. **Confirmed by grep: zero `aws_cloudwatch_metric_alarm`
      and zero `aws_sns_*` resources in any `.tf` file before this change.**
- [x] 1.2 Confirm the ECS cluster already runs Container Insights
      (`deploy/api/modules/service`), so the serving-plane alarms need no new
      agent. **Confirmed: `aws_ecs_cluster.this` sets `containerInsights =
      "enabled"`.**
- [x] 1.3 Confirm the EKS cluster runs no equivalent (no metrics-server, no
      CloudWatch agent), so pod-level batch-plane alarms are out of reach
      without new infrastructure (**G4**, **G7**). **Confirmed against the
      batch-plane operational record: `kubectl top nodes` reports "Metrics API
      not available."**

## 2. Module outputs

- [x] 2.1 `deploy/cron/modules/cluster/outputs.tf`: add
      `system_node_group_asg_name` and `worker_node_group_asg_name`, reading
      `aws_eks_node_group.{system,worker}.resources[0].autoscaling_groups[0].name`.
- [x] 2.2 `deploy/cron/modules/queue/outputs.tf`: add `queue_name` and
      `dlq_name` — `AWS/SQS` CloudWatch metrics dimension by name, not ARN,
      and neither was previously exposed.
- [x] 2.3 `deploy/api/modules/edge/outputs.tf`: add `alb_arn_suffix` and
      `target_group_arn_suffix` — `AWS/ApplicationELB` CloudWatch metrics
      dimension by the short suffix form, not the full ARN already exposed.

## 3. Batch-plane alerting module

- [x] 3.1 Create `deploy/cron/modules/alerting`: SNS topic, email
      subscriptions (**G6**), and the DLQ-depth alarm (**G2**).
- [x] 3.2 Add the queue-backlog-age alarm (**G3**).
- [x] 3.3 Add the system and worker node-group understaffed alarms (**G4**),
      thresholded against each node group's own `desired_size` rather than a
      hardcoded count, so the alarm and the cluster's actual target can't
      drift independently.
- [x] 3.4 Wire `module "alerting"` into `deploy/cron/production/main.tf`; add
      `alert_email_addresses`, `system_desired_size`, and
      `worker_desired_size` to its `variables.tf` (**G8**); pass
      `system_desired_size`/`worker_desired_size` explicitly into
      `module.cluster` too, rather than leaving them at the module's own
      defaults, so the alerting thresholds and the cluster's real capacity
      are the same variable.

## 4. Serving-plane alerting module

- [x] 4.1 Create `deploy/api/modules/alerting`: SNS topic, email
      subscriptions (**G6**), and the three alarms from **G5** (target 5xx,
      unhealthy target count, p90 latency).
- [x] 4.2 Wire `module "alerting"` into
      `deploy/api/environments/production/main.tf`; add
      `alert_email_addresses` to its `variables.tf`, not to
      `environments/staging`'s (**G8**).

## 5. Verification

- [x] 5.1 `tofu fmt -check -recursive -diff deploy/` — clean.
- [x] 5.2 `tofu validate` (via `tofu init -backend=false`) against every
      changed or new directory: both new alerting modules, both edited
      modules (`cluster`, `queue`, `edge`), and both production roots
      (`cron/production`, `api/environments/production`). All pass.
- [ ] 5.3 After apply: confirm each subscribed address receives and accepts
      its SNS confirmation email, and that `scripts/verification/trigger-dlq.sh`
      (already used in `provision-cron-aws` task 9.5) trips the DLQ-depth
      alarm end-to-end. Not run as part of this change — no `tofu apply`
      against the real account is part of this proposal; see `tofu.yml`'s own
      statement that it never holds AWS credentials.

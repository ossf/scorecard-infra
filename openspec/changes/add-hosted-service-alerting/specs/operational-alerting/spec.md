# operational-alerting: Added Requirements

## ADDED Requirements

### Requirement: Each plane's alarms notify a human through its own channel

Every automated health signal for a hosted-services plane SHALL notify a
human through a notification channel scoped to that plane, and SHALL NOT
share a channel with the other plane.

#### Scenario: An alarm fires

- **WHEN** a CloudWatch alarm on either plane enters ALARM state
- **THEN** it SHALL publish to that plane's own notification channel, and a
  subscriber to one plane's channel SHALL NOT receive the other plane's
  alarms

#### Scenario: A plane is provisioned, changed, or destroyed

- **WHEN** one plane's alerting is provisioned, changed, or destroyed
- **THEN** the other plane's alerting resources SHALL be unaffected, matching
  the plane-independence requirement the two planes already deploy under

### Requirement: A dead-letter queue receiving a message is alarmed immediately

The batch plane SHALL alarm on its dead-letter queue holding at least one
message, without waiting for a larger backlog to accumulate, because a
message reaching the dead-letter queue has already exhausted its retries and
represents work already lost.

#### Scenario: A message lands in the dead-letter queue

- **WHEN** the dead-letter queue's visible message count rises above zero
- **THEN** an alarm SHALL fire within one evaluation period, and SHALL NOT
  wait for a threshold greater than one message

#### Scenario: The dead-letter queue is empty

- **WHEN** the dead-letter queue holds no messages
- **THEN** no alarm SHALL fire, and the absence of a CloudWatch datapoint
  SHALL be treated as the healthy state rather than as unknown

### Requirement: A stalled batch run is alarmed before the next scheduled run

The batch plane SHALL alarm when its oldest unprocessed message has been
waiting longer than a completed run is expected to take, so that a stall
without any failed message is still caught before it threatens the next
scheduled run.

#### Scenario: The queue backs up past the threshold

- **WHEN** the age of the oldest message in the main queue exceeds the
  configured backlog-age threshold
- **THEN** an alarm SHALL fire

### Requirement: Batch node-group capacity shortfalls are alarmed

Each of the batch plane's EKS node groups SHALL be alarmed when its
in-service instance count falls below its configured desired capacity, using
a metric that requires no additional monitoring agent.

#### Scenario: A node group cannot reach its desired capacity

- **WHEN** a node group's in-service instance count is below its desired
  size for more than one evaluation period
- **THEN** an alarm SHALL fire

### Requirement: Serving-plane error rate, target health, and latency are alarmed

The serving plane SHALL alarm on an elevated rate of server errors from its
own targets, on any unhealthy target persisting past the load balancer's own
health-check threshold, and on elevated p90 target response time.

#### Scenario: Targets return server errors

- **WHEN** the count of target-origin 5xx responses in an evaluation window
  exceeds the configured threshold
- **THEN** an alarm SHALL fire, counted as a sum over the window rather than
  averaged against request volume

#### Scenario: A target fails its health check

- **WHEN** at least one target is unhealthy for the alarm's own consecutive
  evaluation periods
- **THEN** an alarm SHALL fire, independent of the load balancer's own
  health-check evaluation

#### Scenario: Response time degrades

- **WHEN** the p90 target response time exceeds the configured threshold for
  the alarm's consecutive evaluation periods
- **THEN** an alarm SHALL fire

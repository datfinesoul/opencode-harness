# AWS ECS EC2 with ADOT Instrumentation for Node.js

**Sources:** AWS Distro for OpenTelemetry official docs, OpenTelemetry JS upstream docs  
**Context:** EC2-backed ECS cluster, Node.js test API service, OpenTofu provisioning

---

## Overview

AWS Distro for OpenTelemetry (ADOT) is AWS's distribution of the OpenTelemetry Collector and SDKs. For ECS on EC2, the canonical pattern is:

1. Run the ADOT Collector as a **sidecar container** in the same ECS task as your Node.js app.
2. Instrument your Node.js app to export OTLP telemetry to the sidecar at `localhost:4317` (gRPC) or `localhost:4318` (HTTP).
3. The ADOT Collector forwards traces to X-Ray, metrics to CloudWatch (via EMF), and container metrics via the `awsecscontainermetrics` receiver.

Optionally, run the ADOT Collector as a **daemon service** on each EC2 instance to collect EC2-level host metrics (CPU, disk, network).

---

## Architecture

```
┌────────────────────────────── ECS Task ───────────────────────────────┐
│                                                                        │
│  ┌──────────────────────────┐      ┌───────────────────────────────┐  │
│  │  Node.js API container   │      │   ADOT Collector (sidecar)    │  │
│  │                          │      │   image: amazon/aws-otel-     │  │
│  │  NODE_OPTIONS=           │─────▶│           collector           │  │
│  │  --require @aws/adot...  │ OTLP │                               │  │
│  │  (port 3000)             │      │  receivers: [otlp, xray,      │  │
│  │                          │      │    awsecscontainermetrics,    │  │
│  └──────────────────────────┘      │    statsd]                    │  │
│                                    │                               │  │
│                                    │  exporters: [awsxray, awsemf] │  │
│                                    └──────────┬────────────────────┘  │
└───────────────────────────────────────────────│───────────────────────┘
                                                │
                              ┌─────────────────┴──────────────┐
                              │                                 │
                         AWS X-Ray                    CloudWatch (EMF)
                         (traces)                     (metrics + container
                                                        insights)
```

For EC2 host-level metrics, also deploy the collector as a daemon service:

```
ECS Cluster (EC2)
├── Daemon Service: ADOT Collector
│   └── Collects EC2 instance metrics → CloudWatch
└── Application Service (1..N tasks)
    └── Each task: Node.js app + ADOT sidecar
```

---

## Prerequisites

### Node.js Version Requirements

ADOT JavaScript auto-instrumentation supports Node.js **18, 20, 22, and 24**.

### ECS Agent Version

The `awsecscontainermetrics` receiver requires ECS agent **v1.39.0+** (EC2 launch type) to use Task Metadata Endpoint V4.

---

## Step 1: IAM Setup

### 1.1 Task IAM Policy (`AWSDistroOpenTelemetryPolicy`)

Create a custom policy granting the ADOT Collector access to write to X-Ray, CloudWatch, and read SSM parameters:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
        "xray:PutTraceSegments",
        "xray:PutTelemetryRecords",
        "xray:GetSamplingRules",
        "xray:GetSamplingTargets",
        "xray:GetSamplingStatisticSummaries",
        "cloudwatch:PutMetricData",
        "ec2:DescribeVolumes",
        "ec2:DescribeTags",
        "ssm:GetParameters"
      ],
      "Resource": "*"
    }
  ]
}
```

### 1.2 TaskRole (`AWSOTTaskRole`)

- Trusted entity: **Elastic Container Service Task**
- Attach: `AWSDistroOpenTelemetryPolicy` (created above)

This is the role the running containers use to call AWS APIs.

### 1.3 TaskExecutionRole (`AWSOTTaskExecutionRole`)

- Trusted entity: **Elastic Container Service Task**
- Attach:
  - `AmazonECSTaskExecutionRolePolicy` (pull images, write CloudWatch logs)
  - `CloudWatchLogsFullAccess`
  - `AmazonSSMReadOnlyAccess` (needed if using SSM for custom collector config)

This role grants ECS the permissions needed to start your task (pull images, write startup logs).

---

## Step 2: Node.js App Instrumentation

### 2.1 Install ADOT JavaScript SDK

```bash
npm install @aws/aws-distro-opentelemetry-node-autoinstrumentation
```

This pulls in `@opentelemetry/auto-instrumentations-node`, `@opentelemetry/sdk-node`, and all required upstream packages. It auto-instruments Express, HTTP, AWS SDK, and many other popular libraries.

### 2.2 Enable Auto-Instrumentation

The simplest approach — no code changes to `app.js`:

```bash
# Set in ECS task definition environment or Dockerfile
NODE_OPTIONS="--require @aws/aws-distro-opentelemetry-node-autoinstrumentation/register"
```

Or explicitly at launch:

```bash
node --require '@aws/aws-distro-opentelemetry-node-autoinstrumentation/register' app.js
```

### 2.3 Required Environment Variables for ECS

Set these on the **Node.js container** in the task definition:

| Variable | Value | Purpose |
|---|---|---|
| `NODE_OPTIONS` | `--require @aws/aws-distro-opentelemetry-node-autoinstrumentation/register` | Loads auto-instrumentation |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | OTLP gRPC to sidecar |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | Protocol selection |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.name=my-nodejs-api,service.version=1.0` | Service identity in traces/metrics |
| `OTEL_PROPAGATORS` | `xray,tracecontext,b3` | AWS X-Ray trace propagation |
| `OTEL_TRACES_SAMPLER` | `parentbased_traceidratio` | Sampling strategy |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | 100% sampling (reduce in production) |

For **X-Ray remote sampling** (sampling rules managed centrally):

```
OTEL_TRACES_SAMPLER=xray
OTEL_TRACES_SAMPLER_ARG=endpoint=http://localhost:2000,polling_interval=300
```

The sidecar must expose port 2000 (UDP) for the X-Ray receiver to support remote sampling.

### 2.4 Manual Instrumentation (Optional)

For custom spans alongside auto-instrumentation:

```bash
npm install @opentelemetry/api
```

```js
const { trace } = require('@opentelemetry/api');

const tracer = trace.getTracer('my-service');

async function doWork() {
  return tracer.startActiveSpan('my-custom-span', async (span) => {
    span.setAttribute('custom.key', 'value');
    try {
      // ... work ...
    } finally {
      span.end();
    }
  });
}
```

---

## Step 3: ADOT Collector Configuration

The ADOT Collector image (`amazon/aws-otel-collector`) ships with two built-in configs for ECS:

| Config Path | Use Case |
|---|---|
| `--config=/etc/ecs/ecs-default-config.yaml` | StatsD metrics, OTLP metrics/traces, X-Ray SDK traces |
| `--config=/etc/ecs/container-insights/otel-task-metrics-config.yaml` | All of the above + ECS container resource utilization metrics |

**For a Node.js API with full observability, use the Container Insights config.**

### 3.1 Built-in Container Insights Config (Recommended Starting Point)

Pass this as the `command` in the ADOT container definition:

```json
"command": ["--config=/etc/ecs/container-insights/otel-task-metrics-config.yaml"]
```

This built-in config wires up:
- `receivers`: `otlp`, `awsxray` (UDP 2000), `awsecscontainermetrics`, `statsd`
- `exporters`: `awsxray`, `awsemf` (CloudWatch via EMF)

### 3.2 Custom Config via SSM Parameter (Production Pattern)

For production, store your collector config in AWS SSM Parameter Store and reference it via environment variable. This avoids rebuilding the collector image when config changes.

**SSM Parameter:**
- Name: `otel-collector-config`
- Type: String
- Value: full YAML collector config (see below)

**ADOT container environment variable:**
```json
{
  "name": "AOT_CONFIG_CONTENT",
  "valueFrom": "otel-collector-config"
}
```

**Example custom config for Node.js + ECS EC2:**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  awsxray:
    endpoint: 0.0.0.0:2000
    transport: udp
  awsecscontainermetrics:
    collection_interval: 20s

processors:
  batch:
    timeout: 1s
    send_batch_size: 50
  resource:
    attributes:
      - key: ClusterName
        from_attribute: aws.ecs.cluster.name
        action: insert
      - key: aws.ecs.cluster.name
        action: delete
      - key: ServiceName
        from_attribute: aws.ecs.service.name
        action: insert
      - key: aws.ecs.service.name
        action: delete
      - key: TaskId
        from_attribute: aws.ecs.task.id
        action: insert
      - key: aws.ecs.task.id
        action: delete
      - key: TaskDefinitionFamily
        from_attribute: aws.ecs.task.family
        action: insert
      - key: aws.ecs.task.family
        action: delete
  filter/container_metrics:
    metrics:
      include:
        match_type: strict
        metric_names:
          - ecs.task.memory.reserved
          - ecs.task.memory.utilized
          - ecs.task.cpu.reserved
          - ecs.task.cpu.utilized
          - ecs.task.network.rate.rx
          - ecs.task.network.rate.tx
          - ecs.task.storage.read_bytes
          - ecs.task.storage.write_bytes

exporters:
  awsxray:
    region: us-east-1
  awsemf:
    region: us-east-1
    namespace: ECS/ContainerInsights
    log_group_name: '/aws/ecs/containerinsights/{ClusterName}/performance'
    log_stream_name: '{TaskId}'
    resource_to_telemetry_conversion:
      enabled: true
    dimension_rollup_option: NoDimensionRollup
    metric_declarations:
      - dimensions: [[ClusterName], [ClusterName, TaskDefinitionFamily]]
        metric_name_selectors: [.]
  awsemf/application:
    region: us-east-1
    namespace: 'MyApp/NodeJS'
    log_group_name: '/myapp/metrics'
    resource_to_telemetry_conversion:
      enabled: true

service:
  pipelines:
    traces:
      receivers: [otlp, awsxray]
      processors: [batch]
      exporters: [awsxray]
    metrics/container:
      receivers: [awsecscontainermetrics]
      processors: [filter/container_metrics, resource]
      exporters: [awsemf]
    metrics/app:
      receivers: [otlp]
      processors: [batch]
      exporters: [awsemf/application]
```

---

## Step 4: ECS Task Definition (EC2)

The core pattern for EC2 launch type is `bridge` network mode with `links` connecting containers. The Node.js container links to the `aws-otel-collector` container.

```json
{
  "family": "nodejs-api-with-adot",
  "taskRoleArn": "<AWSOTTaskRole ARN>",
  "executionRoleArn": "<AWSOTTaskExecutionRole ARN>",
  "networkMode": "bridge",
  "requiresCompatibilities": ["EC2"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "aws-otel-collector",
      "image": "amazon/aws-otel-collector",
      "essential": true,
      "command": [
        "--config=/etc/ecs/container-insights/otel-task-metrics-config.yaml"
      ],
      "portMappings": [
        { "hostPort": 4317, "containerPort": 4317, "protocol": "tcp" },
        { "hostPort": 4318, "containerPort": 4318, "protocol": "tcp" },
        { "hostPort": 2000, "containerPort": 2000, "protocol": "udp" },
        { "hostPort": 8125, "containerPort": 8125, "protocol": "udp" }
      ],
      "healthCheck": {
        "command": ["/healthcheck"],
        "interval": 5,
        "timeout": 6,
        "retries": 5,
        "startPeriod": 1
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/adot-collector",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "True"
        }
      }
    },
    {
      "name": "nodejs-api",
      "image": "<your-ecr-image>",
      "essential": true,
      "links": ["aws-otel-collector"],
      "dependsOn": [
        { "containerName": "aws-otel-collector", "condition": "START" }
      ],
      "portMappings": [
        { "hostPort": 3000, "containerPort": 3000, "protocol": "tcp" }
      ],
      "environment": [
        {
          "name": "NODE_OPTIONS",
          "value": "--require @aws/aws-distro-opentelemetry-node-autoinstrumentation/register"
        },
        {
          "name": "OTEL_EXPORTER_OTLP_ENDPOINT",
          "value": "http://aws-otel-collector:4317"
        },
        {
          "name": "OTEL_EXPORTER_OTLP_PROTOCOL",
          "value": "grpc"
        },
        {
          "name": "OTEL_RESOURCE_ATTRIBUTES",
          "value": "service.name=nodejs-api,service.version=1.0"
        },
        {
          "name": "OTEL_PROPAGATORS",
          "value": "xray,tracecontext,b3"
        },
        {
          "name": "OTEL_TRACES_SAMPLER",
          "value": "parentbased_traceidratio"
        },
        {
          "name": "OTEL_TRACES_SAMPLER_ARG",
          "value": "1.0"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/nodejs-api",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "True"
        }
      }
    }
  ]
}
```

**Key EC2 networking notes:**
- `networkMode: "bridge"` is standard for EC2 ECS tasks.
- In bridge mode, containers in the same task communicate via Docker `links` using the container name as hostname (e.g., `http://aws-otel-collector:4317`).
- `awsvpc` mode is an alternative that assigns each task its own ENI; in that case `localhost` works for inter-container communication but requires different port mapping.

---

## Step 5: EC2 Instance-Level Metrics (Daemon Service)

To collect host-level EC2 metrics (not just task/container metrics), deploy the ADOT Collector as a **daemon service** — one instance per EC2 instance in the cluster.

### 5.1 Daemon Task Definition

```json
{
  "family": "adot-daemon-ec2",
  "taskRoleArn": "<AWSOTTaskRole ARN>",
  "executionRoleArn": "<AWSOTTaskExecutionRole ARN>",
  "networkMode": "host",
  "requiresCompatibilities": ["EC2"],
  "containerDefinitions": [
    {
      "name": "aws-otel-collector",
      "image": "amazon/aws-otel-collector",
      "essential": true,
      "command": ["--config=/etc/ecs/container-insights/otel-task-metrics-config.yaml"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/adot-daemon",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "daemon",
          "awslogs-create-group": "True"
        }
      }
    }
  ]
}
```

### 5.2 Deploy as Daemon

Via AWS CLI:

```bash
aws ecs create-service \
  --cluster my-cluster \
  --service-name adot-daemon \
  --task-definition adot-daemon-ec2 \
  --scheduling-strategy DAEMON
```

---

## Step 6: Collector Image Tags and Updates

The ADOT Collector image is hosted on Docker Hub and ECR Public:

```
amazon/aws-otel-collector:latest
amazon/aws-otel-collector:v0.x.y   # pin to specific version in production
```

ECR Public (preferred for ECS to avoid Docker Hub rate limits):

```
public.ecr.aws/aws-observability/aws-otel-collector:latest
```

---

## Observability Outputs

### Traces → AWS X-Ray

- Navigate to **AWS X-Ray** in the console.
- View service maps, trace timelines, and latency distributions.
- Auto-instrumented libraries (Express, HTTP, AWS SDK) produce spans automatically.
- Traces carry X-Ray trace IDs compatible with `aws-xray-sdk` if you need mixed SDK usage.

### Metrics → CloudWatch

Two metric destinations depending on config:

| Namespace | Source | Data |
|---|---|---|
| `ECS/ContainerInsights` | `awsecscontainermetrics` receiver | CPU, memory, network, storage per task/container |
| `MyApp/NodeJS` (custom) | OTLP metrics from your Node.js app | `http.server.duration`, custom business metrics |

The `awsemf` exporter writes metrics as CloudWatch Embedded Metric Format (EMF) log events. CloudWatch automatically extracts these as metrics — no separate `PutMetricData` API calls.

### CloudWatch Application Signals (Optional)

ADOT auto-instrumentation is compatible with **CloudWatch Application Signals**, which provides a unified application health dashboard (SLOs, RED metrics, service map) without any additional SDK configuration. Enable it in the ECS console or by setting the appropriate ADOT config mode.

---

## Configuration Decision Matrix

| Scenario | Recommendation |
|---|---|
| Just traces | Built-in `ecs-default-config.yaml` + `OTEL_TRACES_SAMPLER=xray` |
| Traces + container metrics | Built-in `container-insights/otel-task-metrics-config.yaml` |
| Traces + app custom metrics | Custom config via SSM with separate OTLP metrics pipeline |
| EC2 host metrics | Daemon service with `awscontainerinsightreceiver` or `hostmetrics` receiver |
| Centralized sampling rules | `OTEL_TRACES_SAMPLER=xray` + X-Ray sampling rules in console |
| Config changes without redeployment | SSM Parameter with `AOT_CONFIG_CONTENT` env var |

---

## Community Patterns

### Datadog via ADOT

ADOT supports forwarding telemetry to Datadog using the `datadog` exporter, which can be added alongside the `awsxray` and `awsemf` exporters in a custom config. This allows a single ADOT sidecar to fan out to both AWS-native and third-party backends.

```yaml
exporters:
  awsxray: {}
  datadog:
    api:
      key: ${env:DD_API_KEY}
      site: datadoghq.com
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [awsxray, datadog]
```

### Dynatrace / New Relic / Honeycomb via OTLP Exporter

These vendors accept standard OTLP. Use the `otlp` exporter targeting their ingestion endpoint:

```yaml
exporters:
  otlp/honeycomb:
    endpoint: api.honeycomb.io:443
    headers:
      x-honeycomb-team: ${env:HONEYCOMB_API_KEY}
```

### Splunk

Splunk provides a dedicated ADOT partner config. See: https://aws-otel.github.io/docs/partners/splunk

---

## Key Gotchas and Considerations

**Container startup order:** Always set `dependsOn` with `condition: START` on the ADOT collector. If the collector isn't listening when Node.js starts, initial spans will be dropped (OTLP exporters retry, but early spans may be lost).

**Bridge mode hostnames:** In `bridge` network mode, use `links` and the container name as the hostname (`aws-otel-collector`). Do not use `localhost` — that only works in `awsvpc` or `host` network modes.

**CloudWatch dimensions limit:** The `awsemf` exporter has a 9-dimension limit per metric per CloudWatch's EMF spec. Avoid sending dimension sets that exceed this limit.

**ECS agent version:** Verify your EC2 ECS AMI ships with agent v1.39.0+. The Task Metadata Endpoint V4 (required for `awsecscontainermetrics`) is not available on older agents. Check with:
```bash
curl $ECS_CONTAINER_METADATA_URI_V4/task
```

**Sampling in production:** Default 100% sampling (`1.0`) is fine for testing. For production, use X-Ray remote sampling rules or set `OTEL_TRACES_SAMPLER_ARG` to a lower ratio (e.g., `0.1` = 10%).

**SSM vs baked config:** The SSM `AOT_CONFIG_CONTENT` approach is preferred for production because config changes don't require a task definition revision or redeployment — only a new task launch.

**Node.js ESM apps:** If your app uses ES Modules (`type: "module"` in package.json), the `--require` flag may not work. Use `--experimental-loader=@opentelemetry/instrumentation/hook.mjs` instead. CJS apps are fully supported.

---

## Reference Links

- [ADOT ECS Setup Overview](https://aws-otel.github.io/docs/setup/ecs)
- [ADOT ECS EC2 Task Definition](https://aws-otel.github.io/docs/setup/ecs/task-definition-for-ecs-ec2)
- [ADOT JavaScript SDK Auto-Instrumentation](https://aws-otel.github.io/docs/getting-started/js-sdk/trace-metric-auto-instr)
- [ECS Container Metrics Receiver](https://aws-otel.github.io/docs/components/ecs-metrics-receiver)
- [Custom Config via SSM](https://aws-otel.github.io/docs/setup/ecs/config-through-ssm)
- [IAM Policy](https://aws-otel.github.io/docs/setup/ecs/create-iam-policy)
- [IAM Roles](https://aws-otel.github.io/docs/setup/ecs/create-iam-role)
- [Official EC2 Sidecar Task Definition JSON](https://github.com/aws-observability/aws-otel-collector/blob/master/examples/ecs/aws-cloudwatch/ecs-ec2-sidecar.json)
- [ADOT JS Sample App (Express)](https://github.com/aws-observability/aws-otel-js-instrumentation/tree/main/sample-applications/simple-express-server)
- [OpenTelemetry JS Node.js Getting Started](https://opentelemetry.io/docs/languages/js/getting-started/nodejs/)

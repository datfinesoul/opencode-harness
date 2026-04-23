# AWS ECS EC2 with ADOT / Observe Agent + Observe Inc for Node.js

**Sources:** AWS Distro for OpenTelemetry official docs, Observe Inc official docs, OpenTelemetry JS upstream docs  
**Context:** EC2-backed ECS cluster, Node.js test API service, OpenTofu provisioning, Observe Inc as observability backend

---

## Overview

There are two viable collection approaches for sending telemetry to Observe Inc from ECS EC2:

| Approach | Collector Image | Best For |
|---|---|---|
| **Observe Agent (recommended)** | `observeinc/observe-agent` | Purpose-built for Observe, pre-configured exporters, built-in Observe package routing |
| **Vanilla ADOT + OTLP exporter** | `amazon/aws-otel-collector` | Teams already invested in ADOT config, or needing AWS-native resources (X-Ray, etc.) alongside Observe |

Both options use the **sidecar pattern** on ECS EC2: the collector runs as a container in the same task as your Node.js app. The Node.js app sends OTLP to `localhost`/container-name, and the collector forwards to Observe.

**Key difference from a CloudWatch-only setup:** You replace `awsxray` and `awsemf` exporters with `otlphttp` exporters pointed at `https://<customer_id>.collect.observeinc.com/v2/otel`. Observe natively ingests OTLP HTTP (protobuf). OTLP gRPC is **not** supported at Observe's ingest endpoint — the collector must use HTTP to reach Observe, but can still accept gRPC from local app containers.

For EC2 host-level and container log collection, the Observe Agent also runs as a **daemon service** on each EC2 instance.

---

## Architecture

```
┌────────────────────────────── ECS Task (bridge mode) ─────────────────┐
│                                                                        │
│  ┌──────────────────────────┐      ┌───────────────────────────────┐  │
│  │  Node.js API container   │      │   Observe Agent (sidecar)     │  │
│  │                          │      │   image: observeinc/          │  │
│  │  NODE_OPTIONS=           │─────▶│           observe-agent       │  │
│  │  --require @otel/auto... │OTLP  │                               │  │
│  │  (port 3000)             │HTTP  │  receivers: [otlp,            │  │
│  │                          │      │    awsecscontainermetrics]    │  │
│  └──────────────────────────┘      │                               │  │
│                                    │  exporters:                   │  │
│                                    │   otlphttp/observe (traces)   │  │
│                                    │   otlphttp/observemetrics     │  │
│                                    └──────────┬────────────────────┘  │
└───────────────────────────────────────────────│───────────────────────┘
                                                │ OTLP/HTTP + Bearer token
                                  ┌─────────────▼──────────────────────┐
                                  │  Observe Inc                       │
                                  │  https://<id>.collect.observeinc   │
                                  │  .com/v2/otel                      │
                                  │                                    │
                                  │  - Trace Explorer (APM)            │
                                  │  - Metrics Explorer                │
                                  │  - Log Explorer                    │
                                  └────────────────────────────────────┘
```

For EC2-level host metrics and container logs (daemon pattern):

```
ECS Cluster (EC2)
├── Daemon Service: observe-agent (host network mode)
│   └── Collects: docker logs, host metrics → Observe
└── Application Services (1..N tasks, bridge mode)
    └── Each task: Node.js app + observe-agent sidecar
```

---

## Observe Inc Ingest Basics

### OTLP Endpoint

```
https://<CUSTOMER_ID>.collect.observeinc.com/v2/otel
```

The agent appends the appropriate path suffix per signal type automatically:
- Traces: `.../v2/otel/v1/traces`
- Metrics: `.../v2/otel/v1/metrics`
- Logs: `.../v2/otel/v1/logs`

### Authentication

All requests require a Bearer token in the `Authorization` header:

```
Authorization: Bearer <INGEST_TOKEN>
```

Ingest tokens are created in **Data & Integrations > Add Data** in the Observe UI.

### Protocol

Observe supports OTLP over **HTTP only** (no gRPC at the ingest boundary). Use `http/protobuf` encoding. JSON encoding (`application/json`) is also accepted. Maximum payload: 50MB uncompressed, 10MB compressed.

### `x-observe-target-package` Header

Observe uses an optional routing header to associate incoming telemetry with a specific Observe app/package:

| Signal | Header Value |
|---|---|
| Traces/APM | `Tracing` |
| Metrics | `Metrics` |
| Logs | `Host Explorer` |

---

## Prerequisites

### Node.js Version Requirements

OpenTelemetry JavaScript auto-instrumentation supports Node.js **18, 20, 22, and 24**.

### ECS Agent Version

The `awsecscontainermetrics` receiver requires ECS agent **v1.39.0+** (EC2) to access Task Metadata Endpoint V4.

---

## Step 1: IAM Setup

### 1.1 Task Role Permissions

The Observe Agent only needs to call AWS APIs for metadata enrichment and container metrics. Unlike the pure ADOT/CloudWatch approach, you do **not** need X-Ray or CloudWatch metrics permissions.

Minimum permissions for the ECS task role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "ec2:DescribeRegions",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:DescribeContainerInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

If you want to also retain AWS-native tracing via X-Ray (alongside Observe), add:

```json
"xray:PutTraceSegments",
"xray:PutTelemetryRecords",
"xray:GetSamplingRules",
"xray:GetSamplingTargets"
```

### 1.2 Task Execution Role

Standard ECS execution role. Attach:
- `AmazonECSTaskExecutionRolePolicy` (pull images from ECR, write startup logs)
- `CloudWatchLogsFullAccess` or scoped `logs:CreateLogStream` + `logs:PutLogEvents` for agent container logs

If storing the Observe ingest token in **SSM Parameter Store** (recommended over plaintext env vars), also attach:
- `AmazonSSMReadOnlyAccess`

If storing in **AWS Secrets Manager**, add the appropriate `secretsmanager:GetSecretValue` permission.

---

## Step 2: Observe Agent Configuration

### Option A: Observe Agent (Recommended)

The Observe Agent (`observeinc/observe-agent`) is a pre-configured OpenTelemetry Collector distribution built and maintained by Observe. It handles exporter configuration, retry logic, and Observe-specific routing headers automatically via the `token` and `observe_url` top-level config fields.

**`observe-agent.yaml`** for ECS EC2 sidecar:

```yaml
# Observe ingest token
token: "${TOKEN}"

# Observe collection URL (include trailing slash)
observe_url: "${OBSERVE_URL}"

self_monitoring:
  enabled: true

host_monitoring:
  enabled: false        # disabled in sidecar; enable in daemon service
  logs:
    enabled: false
  metrics:
    host:
      enabled: false
    process:
      enabled: false

forwarding:
  enabled: true
  metrics:
    output_format: otel
  endpoints:
    grpc: 0.0.0.0:4317   # accepts from local Node.js app
    http: 0.0.0.0:4318

resource_attributes:
  service.name: "${SERVICE_NAME}"
  deployment.environment.name: "${ENVIRONMENT}"

otel_config_overrides:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    awsecscontainermetrics:
      collection_interval: 20s

  service:
    pipelines:
      metrics/ecs:
        receivers: [awsecscontainermetrics]
        processors: [memory_limiter, resourcedetection, resourcedetection/cloud, batch]
        exporters: [otlphttp/observemetrics]
```

**Key points:**
- `token` and `observe_url` are the only required fields — the agent auto-configures OTLP exporters with correct authentication headers.
- `otel_config_overrides` merges with the agent's built-in pipeline config rather than replacing it entirely.
- The `awsecscontainermetrics` pipeline is added via `otel_config_overrides` to collect ECS container metrics.
- `resourcedetection` and `resourcedetection/cloud` processors automatically enrich spans/metrics with ECS metadata (cluster name, task ARN, container name, AWS region, etc.).

### Option B: Vanilla ADOT Collector with Observe OTLP Exporter

If you are using `amazon/aws-otel-collector` (the ADOT image) rather than the Observe Agent, replace the `awsxray` and `awsemf` exporters with `otlphttp` exporters targeting Observe. Store the ingest token in SSM and inject via `AOT_CONFIG_CONTENT`.

**Custom ADOT config for Observe:**

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
  awsecscontainermetrics:
    collection_interval: 20s

processors:
  batch:
    timeout: 1s
    send_batch_size: 50
  memory_limiter:
    check_interval: 1s
    limit_mib: 200
  resourcedetection:
    detectors: [env, ecs, ec2]
    timeout: 5s

exporters:
  otlphttp/observetraces:
    endpoint: "${OBSERVE_URL}/v2/otel"
    headers:
      authorization: "Bearer ${OBSERVE_TOKEN}"
      x-observe-target-package: "Tracing"
    sending_queue:
      num_consumers: 4
      queue_size: 100
    retry_on_failure:
      enabled: true
    compression: zstd
  otlphttp/observemetrics:
    endpoint: "${OBSERVE_URL}/v2/otel"
    headers:
      authorization: "Bearer ${OBSERVE_TOKEN}"
      x-observe-target-package: "Metrics"
    sending_queue:
      num_consumers: 4
      queue_size: 100
    retry_on_failure:
      enabled: true
    compression: zstd
  otlphttp/observelogs:
    endpoint: "${OBSERVE_URL}/v2/otel"
    headers:
      authorization: "Bearer ${OBSERVE_TOKEN}"
      x-observe-target-package: "Host Explorer"
    sending_queue:
      num_consumers: 4
      queue_size: 100
    retry_on_failure:
      enabled: true
    compression: zstd

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/observetraces]
    metrics/app:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/observemetrics]
    metrics/ecs:
      receivers: [awsecscontainermetrics]
      processors: [memory_limiter, resourcedetection, batch]
      exporters: [otlphttp/observemetrics]
```

Store this in SSM Parameter Store and reference via `AOT_CONFIG_CONTENT` env var on the ADOT container. See [SSM config delivery](#custom-config-delivery-ssm).

---

## Step 3: Node.js App Instrumentation

Observe's own docs recommend the **upstream OpenTelemetry auto-instrumentation** (`@opentelemetry/auto-instrumentations-node`), not the AWS-specific ADOT package. Both work, but the upstream package is more portable.

### 3.1 Install Dependencies

```bash
npm install --save @opentelemetry/api
npm install --save @opentelemetry/auto-instrumentations-node
```

If you need the AWS-specific ADOT package (e.g., for X-Ray propagation alongside Observe):

```bash
npm install @aws/aws-distro-opentelemetry-node-autoinstrumentation
```

### 3.2 Environment Variables for ECS Task Definition

Set on the **Node.js container**:

| Variable | Value | Notes |
|---|---|---|
| `NODE_OPTIONS` | `--require @opentelemetry/auto-instrumentations-node/register` | Zero-code instrumentation |
| `OTEL_SERVICE_NAME` | `nodejs-api` | Appears in Observe APM service map |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://observe-agent:4318` | HTTP endpoint on the sidecar (bridge mode uses container name) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | Observe requires HTTP, not gRPC, at ingest |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment=test,service.version=1.0` | Enriches all telemetry |
| `OTEL_PROPAGATORS` | `tracecontext,b3` | W3C trace context; use `xray,tracecontext` if also sending to X-Ray |
| `OTEL_TRACES_SAMPLER` | `parentbased_traceidratio` | Head-based sampling |
| `OTEL_TRACES_SAMPLER_ARG` | `1.0` | 100% for testing; tune down in production |

**Important protocol note:** The Node.js app → sidecar leg can use gRPC (`4317`) or HTTP (`4318`). The sidecar → Observe leg **must** use HTTP. The Observe Agent handles this automatically. With vanilla ADOT, configure the `otlphttp` exporter (not `otlp`/gRPC) for Observe export.

### 3.3 If Using ADOT SDK Instead

```
NODE_OPTIONS="--require @aws/aws-distro-opentelemetry-node-autoinstrumentation/register"
OTEL_EXPORTER_OTLP_ENDPOINT=http://aws-otel-collector:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_PROPAGATORS=xray,tracecontext,b3
```

### 3.4 ESM Applications

If your app uses ES Modules (`"type": "module"` in package.json), the `--require` flag won't patch instrumentation correctly. Use:

```bash
node --experimental-loader=@opentelemetry/instrumentation/hook.mjs \
     --require @opentelemetry/auto-instrumentations-node/register \
     app.js
```

In the task definition `NODE_OPTIONS`:

```
--experimental-loader=@opentelemetry/instrumentation/hook.mjs --require @opentelemetry/auto-instrumentations-node/register
```

---

## Step 4: Build and Push the Observe Agent Image

The Observe Agent configuration is baked into a custom Docker image pushed to ECR. This is the pattern used in Observe's official ECS EC2 docs.

### 4.1 Prepare Configuration File

Create `observe-agent.yaml` (from Step 2 above). Use `${TOKEN}` and `${OBSERVE_URL}` as placeholders — these are injected at runtime via ECS environment variables.

### 4.2 Dockerfile

```dockerfile
FROM observeinc/observe-agent:latest
COPY observe-agent.yaml /etc/observe-agent/observe-agent.yaml
```

> For production, pin to a specific version instead of `latest`. Check releases at https://github.com/observeinc/observe-agent/releases

### 4.3 Build and Push to ECR

```bash
# Build (must target amd64 for ECS EC2)
docker buildx build --platform=linux/amd64 -t observe-agent:latest .

# Create ECR repository (first time only)
aws ecr create-repository --repository-name observe/observe-agent --region <your_region>

# Authenticate and push
aws ecr get-login-password --region <your_region> \
  | docker login --username AWS --password-stdin \
    <your_account_id>.dkr.ecr.<your_region>.amazonaws.com

docker tag observe-agent:latest \
  <your_account_id>.dkr.ecr.<your_region>.amazonaws.com/observe/observe-agent:latest

docker push \
  <your_account_id>.dkr.ecr.<your_region>.amazonaws.com/observe/observe-agent:latest
```

---

## Step 5: ECS Task Definition (EC2, Bridge Mode)

```json
{
  "family": "nodejs-api-with-observe",
  "taskRoleArn": "arn:aws:iam::<account_id>:role/<task-role>",
  "executionRoleArn": "arn:aws:iam::<account_id>:role/<execution-role>",
  "networkMode": "bridge",
  "requiresCompatibilities": ["EC2"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "observe-agent",
      "image": "<account_id>.dkr.ecr.<region>.amazonaws.com/observe/observe-agent:latest",
      "essential": true,
      "cpu": 256,
      "memory": 512,
      "portMappings": [
        { "hostPort": 4317, "containerPort": 4317, "protocol": "tcp" },
        { "hostPort": 4318, "containerPort": 4318, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "TOKEN",       "value": "<YOUR_INGEST_TOKEN>" },
        { "name": "OBSERVE_URL", "value": "https://<customer_id>.collect.observeinc.com/" },
        { "name": "SERVICE_NAME", "value": "nodejs-api" },
        { "name": "ENVIRONMENT",  "value": "test" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/observe-agent",
          "awslogs-region": "<region>",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "True"
        }
      }
    },
    {
      "name": "nodejs-api",
      "image": "<account_id>.dkr.ecr.<region>.amazonaws.com/nodejs-api:latest",
      "essential": true,
      "cpu": 256,
      "memory": 512,
      "links": ["observe-agent"],
      "dependsOn": [
        { "containerName": "observe-agent", "condition": "START" }
      ],
      "portMappings": [
        { "hostPort": 3000, "containerPort": 3000, "protocol": "tcp" }
      ],
      "environment": [
        {
          "name": "NODE_OPTIONS",
          "value": "--require @opentelemetry/auto-instrumentations-node/register"
        },
        {
          "name": "OTEL_SERVICE_NAME",
          "value": "nodejs-api"
        },
        {
          "name": "OTEL_EXPORTER_OTLP_ENDPOINT",
          "value": "http://observe-agent:4318"
        },
        {
          "name": "OTEL_EXPORTER_OTLP_PROTOCOL",
          "value": "http/protobuf"
        },
        {
          "name": "OTEL_RESOURCE_ATTRIBUTES",
          "value": "deployment.environment=test,service.version=1.0"
        },
        {
          "name": "OTEL_PROPAGATORS",
          "value": "tracecontext,b3"
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
          "awslogs-region": "<region>",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "True"
        }
      }
    }
  ]
}
```

**EC2 bridge mode networking notes:**
- Containers in the same task communicate via Docker `links`. The Node.js container uses `http://observe-agent:4318` as the OTLP endpoint.
- In `awsvpc` network mode (alternative), use `http://localhost:4318` — no `links` needed, but each task gets its own ENI.
- `dependsOn: START` ensures the agent is listening before Node.js starts.

---

## Step 6: Daemon Service for EC2 Host Metrics and Container Logs

To collect docker container logs and EC2 host-level metrics, deploy the Observe Agent as a **daemon service** — one task per EC2 instance.

The daemon agent config enables `host_monitoring` and uses `filelog` receivers to tail Docker log files via a host volume mount.

### 6.1 Daemon `observe-agent.yaml`

```yaml
token: "${TOKEN}"
observe_url: "${OBSERVE_URL}"

self_monitoring:
  enabled: true

host_monitoring:
  enabled: true
  logs:
    enabled: true
    include: []
  metrics:
    host:
      enabled: true
    process:
      enabled: false

forwarding:
  enabled: false   # not acting as a forwarding sidecar

otel_config_overrides:
  receivers:
    filelog/ecs:
      include: [/var/lib/docker/containers/**/*.log]
      include_file_path: true
      storage: file_storage
      retry_on_failure:
        enabled: true
      max_log_size: 4MiB

  service:
    pipelines:
      logs/ecs:
        receivers: [filelog/ecs]
        processors: [memory_limiter, resourcedetection, resourcedetection/cloud, batch]
        exporters: [otlphttp/observe]
```

### 6.2 Daemon Task Definition

```json
{
  "family": "observe-agent-daemon",
  "taskRoleArn": "arn:aws:iam::<account_id>:role/<task-role>",
  "executionRoleArn": "arn:aws:iam::<account_id>:role/<execution-role>",
  "networkMode": "bridge",
  "requiresCompatibilities": ["EC2"],
  "containerDefinitions": [
    {
      "name": "observe-agent",
      "image": "<account_id>.dkr.ecr.<region>.amazonaws.com/observe/observe-agent:latest",
      "essential": true,
      "cpu": 256,
      "memory": 512,
      "environment": [
        { "name": "TOKEN",       "value": "<YOUR_INGEST_TOKEN>" },
        { "name": "OBSERVE_URL", "value": "https://<customer_id>.collect.observeinc.com/" }
      ],
      "mountPoints": [
        {
          "sourceVolume": "docker_logs",
          "containerPath": "/var/lib/docker/containers",
          "readOnly": true
        },
        {
          "sourceVolume": "docker_sock",
          "containerPath": "/var/run/docker.sock",
          "readOnly": true
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/aws/ecs/observe/observe-agent",
          "awslogs-region": "<region>",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ],
  "volumes": [
    {
      "name": "docker_logs",
      "host": { "sourcePath": "/var/lib/docker/containers" }
    },
    {
      "name": "docker_sock",
      "host": { "sourcePath": "/var/run/docker.sock" }
    }
  ]
}
```

### 6.3 Deploy as Daemon

```bash
aws ecs create-service \
  --cluster <cluster-name> \
  --service-name observe-agent-daemon \
  --task-definition observe-agent-daemon \
  --scheduling-strategy DAEMON \
  --region <region>
```

---

## Step 7: Securing the Ingest Token

### Option A: SSM Parameter Store (Simple)

```bash
aws ssm put-parameter \
  --name "/observe/ingest-token" \
  --value "<YOUR_INGEST_TOKEN>" \
  --type SecureString \
  --region <region>
```

In the task definition, use `valueFrom` instead of `value`:

```json
{
  "name": "TOKEN",
  "valueFrom": "arn:aws:ssm:<region>:<account_id>:parameter/observe/ingest-token"
}
```

The task execution role needs `ssm:GetParameters` permission on that parameter ARN.

### Option B: AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name "observe/ingest-token" \
  --secret-string "<YOUR_INGEST_TOKEN>"
```

```json
{
  "name": "TOKEN",
  "valueFrom": "arn:aws:secretsmanager:<region>:<account_id>:secret:observe/ingest-token"
}
```

The task execution role needs `secretsmanager:GetSecretValue` on that secret ARN.

---

## Custom Config Delivery: SSM (ADOT Path)

If using vanilla ADOT (`amazon/aws-otel-collector`) instead of the Observe Agent, store the full collector YAML in SSM and inject via `AOT_CONFIG_CONTENT`:

```bash
aws ssm put-parameter \
  --name "otel-collector-config" \
  --type String \
  --value "$(cat collector-config.yaml)"
```

In the ADOT container definition:

```json
{
  "name": "AOT_CONFIG_CONTENT",
  "valueFrom": "otel-collector-config"
}
```

This avoids rebuilding the collector image when config changes.

---

## Observe Data Model: What You Get

### Traces → APM / Trace Explorer

- Full distributed traces with spans, span events, and span links stored in separate normalized datasets.
- Auto-instrumented Express routes produce spans with `http.method`, `http.route`, `http.status_code`, `http.url`.
- Resource attributes (service name, ECS task ARN, cluster, region) become `resource_attributes` in Observe.
- Span attributes become `attributes`.
- View in **APM > Trace Explorer** or **APM > Service Management**.

### Metrics → Metrics Explorer

- OTLP metrics are stored with `metric`, `type`, `value`, `unit`, `attributes`, and `resource_attributes` columns.
- ECS container metrics from `awsecscontainermetrics` arrive prefixed with `ecs.task.*` and `container.*`.
- OpenTelemetry runtime metrics from Node.js auto-instrumentation include `http.server.duration`, `nodejs.eventloop.utilization`, `v8js.gc.duration`.
- **Histogram note:** Cumulative histograms are not fully supported by Observe — prefer delta aggregation or use the upstream OTel SDK default (cumulative is the default; configure `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` if hitting issues).

### Logs → Log Explorer

- Container stdout/stderr collected by the daemon filelog receiver appears in **Log Explorer**.
- Structured JSON logs are parsed automatically.
- Logs with `trace_id` and `span_id` fields are automatically correlated to traces in APM.

---

## Configuration Decision Matrix

| Scenario | Recommendation |
|---|---|
| Getting started fast | Observe Agent as sidecar + upstream OTel auto-instrumentation |
| Already using ADOT | Keep ADOT image, swap exporters to `otlphttp` pointing at Observe |
| Container logs collection | Observe Agent daemon service with `filelog/ecs` receiver + docker volume mounts |
| EC2 host metrics | Observe Agent daemon with `host_monitoring.enabled: true` |
| Secure token delivery | SSM SecureString with `valueFrom` in task definition |
| Config changes without image rebuild | `OTEL_CONFIG_OVERRIDES` env var (Observe Agent) or SSM `AOT_CONFIG_CONTENT` (ADOT) |
| Delta histogram metrics | Set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` on Node.js app |

---

## Key Gotchas and Considerations

**Observe only accepts OTLP/HTTP at ingest.** The Observe ingest endpoint does not support gRPC. Your collector's exporter to Observe must be `otlphttp`, not `otlp` (which defaults to gRPC). The Observe Agent handles this transparently. With ADOT, explicitly use the `otlphttp` exporter component.

**Node.js → sidecar can use gRPC or HTTP.** The local app-to-sidecar leg can use either `4317` (gRPC) or `4318` (HTTP). The sidecar converts and forwards over HTTP to Observe. Use `http/protobuf` if you want to keep the full chain HTTP-only.

**Bridge mode hostnames.** In ECS EC2 bridge networking, containers in the same task communicate via Docker `links`. Set `OTEL_EXPORTER_OTLP_ENDPOINT=http://observe-agent:4318` using the container name. Do not use `localhost` — it only works in `awsvpc` or `host` network modes.

**Cumulative histogram warning.** Observe's metric storage doesn't correctly handle cumulative histograms (quantile calculations will be wrong). If your OTel SDK is emitting cumulative histograms (the default for most SDKs), set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` on your Node.js process.

**`x-observe-target-package` header.** This header routes telemetry to the correct Observe app package. Forgetting it means data arrives in a raw datastream but won't appear in the APM or Metrics UI automatically. The Observe Agent adds it for you. With a custom OTLP config, add it explicitly per exporter.

**Token in plaintext env vars is fine for testing**, but use SSM SecureString or Secrets Manager for production. The Observe Agent supports `${TOKEN}` as a placeholder resolved from environment at runtime.

**`OTEL_CONFIG_OVERRIDES` must be a single env var.** When using the Observe Agent's `OTEL_CONFIG_OVERRIDES` override mechanism (as an alternative to baked image config), the entire YAML must be passed as a single environment variable value — not split across multiple vars with `::` delimiters. Splitting silently fails.

**ECS agent version.** The `awsecscontainermetrics` receiver requires ECS agent v1.39.0+. Verify with `curl $ECS_CONTAINER_METADATA_URI_V4/task` on the host — if it returns data, V4 is available.

**Image rate limits.** The Observe Agent image is on Docker Hub (`observeinc/observe-agent`). ECS can be rate-limited by Docker Hub in production. Configure an ECR pull-through cache or build and push to your own ECR repo (the build approach in Step 4 already does this).

---

## Reference Links

### Observe Inc Docs
- [Install on Amazon ECS (EC2)](https://docs.observeinc.com/docs/amazon-ecs-ec2)
- [Install on Amazon ECS (Fargate - Sidecar Pattern)](https://docs.observeinc.com/docs/install-on-amazon-ecs-fargate-sidecar-pattern)
- [Send Node.js application data to Observe](https://docs.observeinc.com/docs/send-nodejs-application-data-to-observe)
- [Instrument your Node.js application on a host](https://docs.observeinc.com/docs/instrument-your-nodejs-application)
- [Configure your own OTel collector (non-Kubernetes)](https://docs.observeinc.com/docs/configure-your-own-otel-collector-in-a-non-kubernetes-environment)
- [OpenTelemetry Endpoint Reference](https://docs.observeinc.com/docs/opentelemetry)
- [APM Instrumentation Overview](https://docs.observeinc.com/docs/apm-instrumentation)

### AWS / ADOT Docs
- [ADOT ECS Setup Overview](https://aws-otel.github.io/docs/setup/ecs)
- [ADOT ECS EC2 Task Definition](https://aws-otel.github.io/docs/setup/ecs/task-definition-for-ecs-ec2)
- [ECS Container Metrics Receiver](https://aws-otel.github.io/docs/components/ecs-metrics-receiver)
- [Custom Config via SSM (ADOT)](https://aws-otel.github.io/docs/setup/ecs/config-through-ssm)
- [Official EC2 Sidecar Task Definition JSON](https://github.com/aws-observability/aws-otel-collector/blob/master/examples/ecs/aws-cloudwatch/ecs-ec2-sidecar.json)

### OpenTelemetry Docs
- [OpenTelemetry JS Node.js Getting Started](https://opentelemetry.io/docs/languages/js/getting-started/nodejs/)
- [ADOT JavaScript SDK Auto-Instrumentation](https://aws-otel.github.io/docs/getting-started/js-sdk/trace-metric-auto-instr)

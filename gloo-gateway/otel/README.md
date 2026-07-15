# OTel Collector Enablement Pattern for Gloo Gateway

Production-ready OpenTelemetry collector setup for scraping metrics from Gloo Gateway components.

**Reference:** [Solo.io Gateway Metrics Docs](https://docs.solo.io/gateway/1.20.x/observability/metrics/)

## Overview

This deploys an independent, standalone OTel collector using the community Helm chart. It scrapes metrics from three categories of Gloo Gateway components and re-exposes them on a single Prometheus-compatible endpoint.

| Receiver | What it scrapes | Pod label selector | Example metrics |
|----------|----------------|-------------------|-----------------|
| `prometheus/gloo-dataplane` | Envoy gateway proxies (`gloo-proxy-*`) | `gloo=kube-gateway` | `envoy_cluster_upstream_rq_total`, `envoy_http_downstream_rq_total` |
| `prometheus/gloo-controlplane` | Gloo control plane (`gloo`) | `gloo=gloo` | `api_gloosnapshot_*`, `gloo_edge_translation_time_sec` |
| `prometheus/gloo-addons` | ExtAuth and Rate Limiting | `gloo=extauth\|rate-limit` | `glooe_extauth_*`, `glooe_ratelimit_*` |

This is separate from the built-in `gloo-telemetry-collector` shipped with the `gloo-platform` chart (which feeds the Solo UI dashboard). Both can coexist without conflicts.

## Prerequisites

- Gloo Gateway Enterprise installed (1.21.x or 2.x with K8s Gateway API mode)
- Helm 3.x
- `kubectl` access to the target cluster

## Deploy

### 1. Add the OTel Helm repo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### 2. Install the collector

```bash
helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
--version 0.97.1 \
--set mode=deployment \
--set image.repository="otel/opentelemetry-collector-contrib" \
--set command.name="otelcol-contrib" \
--namespace=otel \
--create-namespace \
-f -<<'EOF'
clusterRole:
  create: true
  rules:
  - apiGroups:
    - ''
    resources:
    - 'pods'
    - 'nodes'
    verbs:
    - 'get'
    - 'list'
    - 'watch'
ports:
  promexporter:
    enabled: true
    containerPort: 9099
    servicePort: 9099
    protocol: TCP
config:
  receivers:
    prometheus/gloo-dataplane:
      config:
        scrape_configs:
        - job_name: gloo-gateways
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: kube-gateway
              source_labels:
              - __meta_kubernetes_pod_label_gloo
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels:
              - __meta_kubernetes_pod_ip
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              separator: ':'
              target_label: __address__
            - action: labelmap
              regex: __meta_kubernetes_pod_label_(.+)
            - source_labels: [__meta_kubernetes_namespace]
              action: replace
              target_label: kube_namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod
    prometheus/gloo-controlplane:
      config:
        scrape_configs:
        - job_name: gloo-controlplane
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: gloo
              source_labels:
              - __meta_kubernetes_pod_label_gloo
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels:
              - __meta_kubernetes_pod_ip
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              separator: ':'
              target_label: __address__
            - action: labelmap
              regex: __meta_kubernetes_pod_label_(.+)
            - source_labels: [__meta_kubernetes_namespace]
              action: replace
              target_label: kube_namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod
    prometheus/gloo-addons:
      config:
        scrape_configs:
        - job_name: gloo-addons
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: extauth|rate-limit
              source_labels:
              - __meta_kubernetes_pod_label_gloo
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels:
              - __meta_kubernetes_pod_ip
              - __meta_kubernetes_pod_annotation_prometheus_io_port
              separator: ':'
              target_label: __address__
            - action: labelmap
              regex: __meta_kubernetes_pod_label_(.+)
            - source_labels: [__meta_kubernetes_namespace]
              action: replace
              target_label: kube_namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod
  processors:
    batch:
      send_batch_size: 2000
      send_batch_max_size: 3000
      timeout: 600ms
    memory_limiter:
      check_interval: 1s
      limit_percentage: 80
      spike_limit_percentage: 15
  exporters:
    prometheus:
      endpoint: 0.0.0.0:9099
    debug: {}
  service:
    pipelines:
      metrics:
        receivers: [prometheus/gloo-dataplane, prometheus/gloo-controlplane, prometheus/gloo-addons]
        processors: [memory_limiter, batch]
        exporters: [prometheus]
EOF
```

### 3. Verify

```bash
kubectl -n otel get pods
# Expected: opentelemetry-collector-xxxxx   1/1   Running
```

## Validate Metrics

Port-forward and check that all three receiver categories are producing metrics:

```bash
kubectl -n otel port-forward deploy/opentelemetry-collector 9099 & PID=$!
sleep 5

# Data plane (Envoy proxy)
curl -s http://localhost:9099/metrics | grep ^envoy_ | grep -v '^#' | head -5

# Control plane (Gloo controller)
curl -s http://localhost:9099/metrics | grep 'job="gloo-controlplane"' | grep -v '^#' | head -5

# Addons (ExtAuth, Rate Limiting)
curl -s http://localhost:9099/metrics | grep 'job="gloo-addons"' | grep -v '^#' | head -5

kill $PID
```

## Connect to External Prometheus

### Option A: PodMonitor (for kube-prometheus-stack)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: otel-monitor
  namespace: otel
spec:
  podMetricsEndpoints:
  - interval: 30s
    port: promexporter
    scheme: http
  selector:
    matchLabels:
      app.kubernetes.io/name: opentelemetry-collector
```

### Option B: Static scrape config

```yaml
scrape_configs:
- job_name: otel-collector
  static_configs:
  - targets:
    - opentelemetry-collector.otel.svc.cluster.local:9099
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                       │
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌────────────────┐  │
│  │  gloo-proxy-*   │  │      gloo       │  │ extauth /      │  │
│  │  (Data Plane)   │  │ (Control Plane) │  │ rate-limit     │  │
│  │  gloo=          │  │  gloo=gloo      │  │ (Addons)       │  │
│  │  kube-gateway   │  │  :9091/metrics  │  │ :9091/metrics  │  │
│  │  :9091/metrics  │  │                 │  │                │  │
│  └────────┬────────┘  └────────┬────────┘  └───────┬────────┘  │
│           │                    │                    │            │
│           ▼                    ▼                    ▼            │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │            OTel Collector (namespace: otel)              │    │
│  │                                                         │    │
│  │  Receivers:                                             │    │
│  │    prometheus/gloo-dataplane                            │    │
│  │    prometheus/gloo-controlplane                         │    │
│  │    prometheus/gloo-addons                               │    │
│  │                                                         │    │
│  │  Processors: memory_limiter -> batch                    │    │
│  │                                                         │    │
│  │  Exporter:                                              │    │
│  │    prometheus (0.0.0.0:9099)                            │    │
│  └────────────────────────┬────────────────────────────────┘    │
│                           │                                     │
│                           ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │        External Prometheus (scrapes :9099/metrics)       │    │
│  │        -> Grafana dashboards                             │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Things to Know

**Pod label selectors** — The receivers use the `gloo` pod label for Kubernetes service discovery. Verify your pods match before deploying:

```bash
kubectl get pods -A -l gloo=kube-gateway        # data plane
kubectl get pods -A -l gloo=gloo                 # control plane
kubectl get pods -A -l 'gloo in (extauth, rate-limit)'  # addons
```

**Prometheus annotations** — All Gloo Gateway pods need these annotations (set by default in the Helm chart):

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "9091"
prometheus.io/path: "/metrics"
```

**Memory limiter** — The `memory_limiter` processor prevents OOM kills under high cardinality. For production, add resource limits:

```yaml
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi
```

**Custom pipelines pitfall** — When adding custom pipelines, every referenced processor, receiver, and exporter must be defined. The OTel collector validates all references at startup and refuses to start if any component is missing. This applies both to this standalone collector and to the built-in `gloo-platform` telemetry collector when using `telemetryCollectorCustomization.extraPipelines`.

## Cleanup

```bash
helm uninstall opentelemetry-collector -n otel
kubectl delete namespace otel
```

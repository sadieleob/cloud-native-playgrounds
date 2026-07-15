# OTel Collector for Ambient Mesh + kgateway (Multicluster)

Standalone OpenTelemetry collector setup for scraping metrics from Istio ambient mesh and kgateway components in a multicluster environment.

**Reference:** [Solo.io Gateway Metrics Docs](https://docs.solo.io/gateway/latest/observability/metrics/) | [Istio Standard Metrics](https://istio.io/latest/docs/reference/config/metrics/)

## Overview

Each cluster gets its own OTel collector instance. The collector scrapes Prometheus-format metrics from all mesh and gateway components using Kubernetes service discovery, then re-exposes them on a single endpoint (port `9099`) for external Prometheus consumption.

This is separate from the built-in `gloo-telemetry-collector` shipped with the `gloo-platform` chart (which feeds the Solo UI dashboard). Both can coexist.

### Primary Cluster — 7 Receivers

The primary cluster runs both Istio ambient and kgateway, so it needs receivers for both:

| Receiver | Targets | Pod Label Selector | Port | Path |
|----------|---------|-------------------|------|------|
| `prometheus/istiod` | Istio control plane | `app=istiod` | 15014 | `/metrics` |
| `prometheus/ztunnel` | L4 data plane (DaemonSet) | `app=ztunnel` | 15020 | `/metrics` |
| `prometheus/waypoint` | L7 waypoint proxies | `gateway.networking.k8s.io/gateway-class-name=istio-waypoint` | 15020 | `/stats/prometheus` |
| `prometheus/eastwest` | HBONE tunnel gateways | `service.istio.io/canonical-name=istio-eastwest` | 15020 | `/stats/prometheus` |
| `prometheus/kgateway-dataplane` | Envoy gateway proxies | `kgateway=kube-gateway` | 9091 | `/metrics` |
| `prometheus/kgateway-controlplane` | kgateway controller | `kgateway=kgateway` | 9092 | `/metrics` |
| `prometheus/kgateway-addons` | ExtAuth, Rate Limiter | `app=ext-auth-service\|rate-limiter` | 9091 | `/metrics` |

### Secondary Cluster — 4 Receivers

The secondary cluster runs Istio ambient only (no kgateway), so it only needs Istio receivers:

| Receiver | Targets | Pod Label Selector | Port | Path |
|----------|---------|-------------------|------|------|
| `prometheus/istiod` | Istio control plane | `app=istiod` | 15014 | `/metrics` |
| `prometheus/ztunnel` | L4 data plane (DaemonSet) | `app=ztunnel` | 15020 | `/metrics` |
| `prometheus/waypoint` | L7 waypoint proxies | `gateway.networking.k8s.io/gateway-class-name=istio-waypoint` | 15020 | `/stats/prometheus` |
| `prometheus/eastwest` | HBONE tunnel gateways | `service.istio.io/canonical-name=istio-eastwest` | 15020 | `/stats/prometheus` |

## Prerequisites

- Istio ambient mesh installed (1.28.x+ with ztunnel L7 enabled)
- kgateway Enterprise installed on primary cluster
- Helm 3.x
- `kubectl` access to both clusters

## Deploy

### 1. Add the OTel Helm repo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### 2. Install on Primary Cluster (Istio + kgateway)

```bash
export CTX_PRIMARY=<your-primary-context>

helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
--kube-context $CTX_PRIMARY \
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
  - apiGroups: ['']
    resources: ['pods', 'nodes']
    verbs: ['get', 'list', 'watch']
ports:
  promexporter:
    enabled: true
    containerPort: 9099
    servicePort: 9099
    protocol: TCP
config:
  receivers:
    prometheus/istiod:
      config:
        scrape_configs:
        - job_name: istiod
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istiod
              source_labels: [__meta_kubernetes_pod_label_app]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/ztunnel:
      config:
        scrape_configs:
        - job_name: ztunnel
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: ztunnel
              source_labels: [__meta_kubernetes_pod_label_app]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/waypoint:
      config:
        scrape_configs:
        - job_name: waypoint-proxies
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istio-waypoint
              source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_class_name]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/eastwest:
      config:
        scrape_configs:
        - job_name: istio-eastwest
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istio-eastwest
              source_labels: [__meta_kubernetes_pod_label_service_istio_io_canonical_name]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/kgateway-dataplane:
      config:
        scrape_configs:
        - job_name: kgateway-proxies
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: kube-gateway
              source_labels: [__meta_kubernetes_pod_label_kgateway]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/kgateway-controlplane:
      config:
        scrape_configs:
        - job_name: kgateway-controlplane
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: kgateway
              source_labels: [__meta_kubernetes_pod_label_kgateway]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/kgateway-addons:
      config:
        scrape_configs:
        - job_name: kgateway-addons
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: ext-auth-service|rate-limiter
              source_labels: [__meta_kubernetes_pod_label_app]
            - action: drop
              regex: istiod|ztunnel
              source_labels: [__meta_kubernetes_pod_label_app]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_label_gateway_solo_io_gatewayclass]
              action: keep
              regex: enterprise-kgateway
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
        receivers: [prometheus/istiod, prometheus/ztunnel, prometheus/waypoint, prometheus/eastwest, prometheus/kgateway-dataplane, prometheus/kgateway-controlplane, prometheus/kgateway-addons]
        processors: [memory_limiter, batch]
        exporters: [prometheus]
EOF
```

### 3. Install on Secondary Cluster (Istio only)

```bash
export CTX_SECONDARY=<your-secondary-context>

helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
--kube-context $CTX_SECONDARY \
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
  - apiGroups: ['']
    resources: ['pods', 'nodes']
    verbs: ['get', 'list', 'watch']
ports:
  promexporter:
    enabled: true
    containerPort: 9099
    servicePort: 9099
    protocol: TCP
config:
  receivers:
    prometheus/istiod:
      config:
        scrape_configs:
        - job_name: istiod
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istiod
              source_labels: [__meta_kubernetes_pod_label_app]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/ztunnel:
      config:
        scrape_configs:
        - job_name: ztunnel
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: ztunnel
              source_labels: [__meta_kubernetes_pod_label_app]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/waypoint:
      config:
        scrape_configs:
        - job_name: waypoint-proxies
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istio-waypoint
              source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_class_name]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
    prometheus/eastwest:
      config:
        scrape_configs:
        - job_name: istio-eastwest
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: istio-eastwest
              source_labels: [__meta_kubernetes_pod_label_service_istio_io_canonical_name]
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - action: replace
              source_labels: [__meta_kubernetes_pod_ip, __meta_kubernetes_pod_annotation_prometheus_io_port]
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
        receivers: [prometheus/istiod, prometheus/ztunnel, prometheus/waypoint, prometheus/eastwest]
        processors: [memory_limiter, batch]
        exporters: [prometheus]
EOF
```

### 4. Verify

```bash
kubectl --context $CTX_PRIMARY -n otel get pods
kubectl --context $CTX_SECONDARY -n otel get pods
# Expected: opentelemetry-collector-xxxxx   1/1   Running
```

## Validate Metrics

Port-forward and check that all receiver jobs are producing metrics:

```bash
# Primary cluster
kubectl --context $CTX_PRIMARY -n otel port-forward deploy/opentelemetry-collector 9099 & PID=$!
sleep 5

# List all discovered scrape targets
curl -s http://localhost:9099/metrics | grep '^target_info' | grep -oP 'job="[^"]+"' | sort | uniq -c

# Istio control plane
curl -s http://localhost:9099/metrics | grep 'pilot_xds_pushes' | head -3

# ztunnel L4 metrics
curl -s http://localhost:9099/metrics | grep 'istio_tcp_' | head -3

# Waypoint L7 metrics (Envoy)
curl -s http://localhost:9099/metrics | grep 'job="waypoint-proxies"' | head -3

# East-west gateway
curl -s http://localhost:9099/metrics | grep 'job="istio-eastwest"' | head -3

# kgateway proxy (Envoy)
curl -s http://localhost:9099/metrics | grep 'job="kgateway-proxies"' | head -3

# kgateway controller
curl -s http://localhost:9099/metrics | grep 'job="kgateway-controlplane"' | head -3

# kgateway addons (ExtAuth, Rate Limiter)
curl -s http://localhost:9099/metrics | grep 'job="kgateway-addons"' | head -3

kill $PID
```

```bash
# Secondary cluster
kubectl --context $CTX_SECONDARY -n otel port-forward deploy/opentelemetry-collector 9098:9099 & PID=$!
sleep 5

curl -s http://localhost:9098/metrics | grep '^target_info' | grep -oP 'job="[^"]+"' | sort | uniq -c

kill $PID
```

## Connect to External Prometheus

### Option A: PodMonitor (for kube-prometheus-stack)

Apply on each cluster:

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
┌──────────────────────────────────────────────────────────────────────────┐
│                          Primary Cluster                                 │
│                                                                          │
│  Istio Ambient                              kgateway                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐   ┌──────────┐ ┌──────────┐   │
│  │ istiod   │ │ ztunnel  │ │ waypoint │   │ kgateway │ │ kgateway │   │
│  │ :15014   │ │ :15020   │ │ :15020   │   │ proxy    │ │ ctrl     │   │
│  │          │ │ (DaemonS)│ │ (L7)     │   │ :9091    │ │ :9092    │   │
│  └─────┬────┘ └─────┬────┘ └─────┬────┘   └─────┬────┘ └─────┬────┘   │
│        │            │            │              │            │          │
│  ┌─────┴────┐                         ┌──────────┐ ┌──────────┐       │
│  │ eastwest │                         │ ext-auth │ │ rate-    │       │
│  │ :15020   │                         │ :9091    │ │ limiter  │       │
│  └─────┬────┘                         └─────┬────┘ │ :9091    │       │
│        │                                    │      └─────┬────┘       │
│        ▼            ▼            ▼          ▼     ▼      ▼            │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │                OTel Collector (ns: otel)                       │    │
│  │  7 receivers → memory_limiter → batch → prometheus (:9099)    │    │
│  └───────────────────────────┬────────────────────────────────────┘    │
│                              ▼                                        │
│                   External Prometheus                                 │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                         Secondary Cluster                                │
│                                                                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐                   │
│  │ istiod   │ │ ztunnel  │ │ waypoint │ │ eastwest │                   │
│  │ :15014   │ │ :15020   │ │ :15020   │ │ :15020   │                   │
│  └─────┬────┘ └─────┬────┘ └─────┬────┘ └─────┬────┘                   │
│        ▼            ▼            ▼            ▼                         │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │                OTel Collector (ns: otel)                       │    │
│  │  4 receivers → memory_limiter → batch → prometheus (:9099)    │    │
│  └───────────────────────────┬────────────────────────────────────┘    │
│                              ▼                                        │
│                   External Prometheus                                 │
└──────────────────────────────────────────────────────────────────────────┘
```

## Key Metrics by Component

| Component | Key Metrics | What They Tell You |
|-----------|------------|-------------------|
| istiod | `pilot_xds_pushes`, `pilot_proxy_convergence_time`, `citadel_server_csr_count` | Config push rate, convergence time, certificate signing |
| ztunnel | `istio_tcp_connections_opened_total`, `istio_tcp_sent_bytes_total`, `istio_dns_requests_total` | L4 traffic volume, connection counts, DNS interception |
| waypoint | `envoy_http_downstream_rq_total`, `envoy_cluster_upstream_rq_total` | L7 request rates, upstream health |
| eastwest | `istio_tcp_connections_opened_total` | Cross-cluster HBONE tunnel traffic |
| kgateway proxy | `envoy_http_downstream_rq_total`, `envoy_cluster_upstream_rq_total` | Gateway ingress traffic |
| kgateway ctrl | `enterprise_kgateway_controller_reconcile_duration_seconds` | Reconciliation performance |
| ext-auth | `runtime_goroutines_total`, `scrape_duration_seconds` | Auth service health |
| rate-limiter | `runtime_goroutines_total` | Rate limiter health |

## Cleanup

```bash
# Primary
helm uninstall opentelemetry-collector -n otel --kube-context $CTX_PRIMARY
kubectl delete namespace otel --context $CTX_PRIMARY

# Secondary
helm uninstall opentelemetry-collector -n otel --kube-context $CTX_SECONDARY
kubectl delete namespace otel --context $CTX_SECONDARY
```

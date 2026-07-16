# OTel Collector for kgateway + Ambient Mesh (Multicluster)

Standalone OpenTelemetry collector setup for scraping metrics from kgateway and Istio ambient mesh components in a multicluster environment.

**Reference:** [Solo.io Prometheus Scrape Config](https://docs.solo.io/istio/latest/setup/observability/prometheus/) | [Solo.io kgateway Metrics](https://docs.solo.io/gateway/latest/observability/metrics/)

## Overview

Each cluster gets its own OTel collector instance. The collector scrapes Prometheus-format metrics from kgateway and Istio ambient components using Kubernetes service discovery, then re-exposes them on a single endpoint (port `9099`) for external Prometheus consumption.

This is separate from the built-in `gloo-telemetry-collector` shipped with the `gloo-platform` chart (which feeds the Solo UI dashboard). Both can coexist.

### Scrape Job Design

The Istio receivers follow the [Solo.io documented scrape patterns](https://docs.solo.io/istio/latest/setup/observability/prometheus/):

- **istiod** — uses `__meta_kubernetes_pod_label_istio` with regex `pilot|istiod` (covers both label conventions across Istio versions)
- **ztunnel** — uses `__meta_kubernetes_pod_label_app` with regex `ztunnel`
- **gateway** — uses `__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name` with regex `.+` to catch all Gateway API-managed pods (waypoints, east-west gateways). A drop rule excludes `enterprise-kgateway` gateway-class pods to avoid overlap with the dedicated kgateway receiver.

The kgateway receivers use product-specific labels:

- **kgateway-proxies** — uses `kgateway=kube-gateway` to select Envoy proxy pods managed by kgateway
- **kgateway-controlplane** — uses `kgateway=kgateway` to select the kgateway controller
- **kgateway-addons** — uses `app=ext-auth-service|rate-limiter` combined with `gateway.solo.io/gatewayclass=enterprise-kgateway`

All jobs include a `pod_phase` drop rule to skip `Pending|Succeeded|Failed|Completed` pods.

> **Note on OTel config parser:** The Solo docs use regex `$1`/`$2` backreferences for `__address__` construction. The OTel config parser interprets `$1` as environment variable substitution and refuses to start. This config uses `separator: ':'` instead, which produces the same result without the parser conflict.

### Primary Cluster — 6 Receivers

The primary cluster runs both kgateway and Istio ambient:

| Receiver | Targets | Selector | Key Metrics |
|----------|---------|----------|-------------|
| `prometheus/istiod` | Istio control plane | `istio=pilot\|istiod` | `pilot_xds_pushes`, `pilot_proxy_convergence_time` |
| `prometheus/ztunnel` | L4 data plane (DaemonSet) | `app=ztunnel` | `istio_tcp_connections_opened_total`, `istio_tcp_sent_bytes_total` |
| `prometheus/gateway` | Waypoints + east-west gateways | `gateway.networking.k8s.io/gateway-name=.+` | `envoy_http_downstream_rq_total`, `istio_tcp_connections_opened_total` |
| `prometheus/kgateway-dataplane` | kgateway Envoy proxies | `kgateway=kube-gateway` | `envoy_http_downstream_rq_total`, `envoy_cluster_upstream_rq_total` |
| `prometheus/kgateway-controlplane` | kgateway controller | `kgateway=kgateway` | controller reconcile duration |
| `prometheus/kgateway-addons` | ExtAuth, Rate Limiter | `app=ext-auth-service\|rate-limiter` | auth/rate-limit service health |

### Secondary Cluster — 3 Receivers

The secondary cluster runs Istio ambient only (no kgateway):

| Receiver | Targets | Selector |
|----------|---------|----------|
| `prometheus/istiod` | Istio control plane | `istio=pilot\|istiod` |
| `prometheus/ztunnel` | L4 data plane (DaemonSet) | `app=ztunnel` |
| `prometheus/gateway` | Waypoints + east-west gateways | `gateway.networking.k8s.io/gateway-name=.+` |

## Prerequisites

- kgateway Enterprise installed on primary cluster
- Istio ambient mesh installed (Solo Enterprise for Istio 1.28.x+)
- Helm 3.x
- `kubectl` access to both clusters

## Deploy

### 1. Add the OTel Helm repo

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### 2. Install on Primary Cluster (kgateway + Istio)

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
              regex: pilot|istiod
              source_labels: [__meta_kubernetes_pod_label_istio]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
    prometheus/gateway:
      config:
        scrape_configs:
        - job_name: gateway
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: .+
              source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name]
            - action: drop
              regex: enterprise-kgateway
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
        receivers: [prometheus/istiod, prometheus/ztunnel, prometheus/gateway, prometheus/kgateway-dataplane, prometheus/kgateway-controlplane, prometheus/kgateway-addons]
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
              regex: pilot|istiod
              source_labels: [__meta_kubernetes_pod_label_istio]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
    prometheus/gateway:
      config:
        scrape_configs:
        - job_name: gateway
          honor_labels: true
          kubernetes_sd_configs:
          - role: pod
          relabel_configs:
            - action: keep
              regex: .+
              source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name]
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
              target_label: namespace
            - source_labels: [__meta_kubernetes_pod_name]
              action: replace
              target_label: pod_name
            - action: drop
              regex: Pending|Succeeded|Failed|Completed
              source_labels: [__meta_kubernetes_pod_phase]
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
        receivers: [prometheus/istiod, prometheus/ztunnel, prometheus/gateway]
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

# Check all jobs have targets
curl -s http://localhost:9099/metrics | grep '^up{' | grep -oP 'job="[^"]+"' | sort | uniq -c

# kgateway proxy (Envoy)
curl -s http://localhost:9099/metrics | grep 'job="kgateway-proxies"' | head -3

# kgateway controller
curl -s http://localhost:9099/metrics | grep 'job="kgateway-controlplane"' | head -3

# kgateway addons (ExtAuth, Rate Limiter)
curl -s http://localhost:9099/metrics | grep 'job="kgateway-addons"' | head -3

# Istio control plane
curl -s http://localhost:9099/metrics | grep 'pilot_xds_pushes' | head -3

# ztunnel L4 metrics
curl -s http://localhost:9099/metrics | grep 'istio_tcp_' | head -3

# Gateway (waypoints + east-west)
curl -s http://localhost:9099/metrics | grep 'job="gateway"' | head -3

kill $PID
```

```bash
# Secondary cluster
kubectl --context $CTX_SECONDARY -n otel port-forward deploy/opentelemetry-collector 9098:9099 & PID=$!
sleep 5

curl -s http://localhost:9098/metrics | grep '^up{' | grep -oP 'job="[^"]+"' | sort | uniq -c

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
Primary Cluster (kgateway + Istio ambient)
===========================================

  kgateway                                   Istio Ambient
  +-----------+ +-----------+ +-----------+  +-----------+ +-----------+
  | kgateway  | | kgateway  | | ext-auth  |  | istiod    | | ztunnel   |
  | proxy     | | ctrl      | | rate-lim  |  | :15014    | | :15020    |
  | :9091     | | :9092     | | :9091     |  |           | | (DaemonS) |
  +-----+-----+ +-----+-----+ +-----+-----+  +-----+-----+ +-----+-----+
        |             |             |               |             |
                                          +-----------+ +-----------+
                                          | waypoint  | | eastwest  |
                                          | :15020    | | :15020    |
                                          +-----+-----+ +-----+-----+
        v             v             v          v     v        v
  +-----------------------------------------------------------+
  |              OTel Collector (ns: otel)                      |
  |  6 receivers -> memory_limiter -> batch -> prometheus:9099  |
  +-----------------------------+-------------------------------+
                                v
                     External Prometheus


Secondary Cluster (Istio ambient only)
=======================================

  +-----------+ +-----------+ +-----------+ +-----------+
  | istiod    | | ztunnel   | | waypoint  | | eastwest  |
  | :15014    | | :15020    | | :15020    | | :15020    |
  +-----+-----+ +-----+-----+ +-----+-----+ +-----+-----+
        v             v             v             v
  +-----------------------------------------------------------+
  |              OTel Collector (ns: otel)                      |
  |  3 receivers -> memory_limiter -> batch -> prometheus:9099  |
  +-----------------------------+-------------------------------+
                                v
                     External Prometheus
```

## Ambient Mesh Considerations

- The OTel collector namespace (`otel`) does **not** need ambient enrollment. Metric endpoints serve over cleartext HTTP regardless of mesh mTLS mode. Enrollment is only required if the cluster enforces mesh-wide STRICT mTLS via PeerAuthentication, which is uncommon in ambient deployments.
- The `gateway` receiver catches both waypoint proxies and east-west gateways using the `gateway.networking.k8s.io/gateway-name` label. This is the same selector pattern from the [Solo.io scrape config docs](https://docs.solo.io/istio/latest/setup/observability/prometheus/).
- kgateway proxies also carry the `gateway.networking.k8s.io/gateway-name` label. The `gateway` receiver includes a drop rule for `enterprise-kgateway` gateway-class pods to avoid duplicate scraping with the dedicated `kgateway-dataplane` receiver.

## Label Overlap Between kgateway and Istio Gateways

kgateway-managed Envoy proxies carry both `kgateway=kube-gateway` and `gateway.networking.k8s.io/gateway-name=<name>` labels. Without the drop rule in the `gateway` job, these pods would be scraped by both the `gateway` and `kgateway-proxies` jobs. The drop rule uses `gateway.networking.k8s.io/gateway-class-name=enterprise-kgateway` to exclude kgateway pods from the Istio gateway job.

To verify this in your cluster:

```bash
# Show pods that would match both jobs without the drop rule
kubectl get pods -A -l 'gateway.networking.k8s.io/gateway-name,kgateway=kube-gateway' \
  -o custom-columns='NAME:.metadata.name,NAMESPACE:.metadata.namespace,GATEWAY-CLASS:.metadata.labels.gateway\.networking\.k8s\.io/gateway-class-name'
```

## Key Metrics by Component

| Component | Key Metrics | What They Tell You |
|-----------|------------|-------------------|
| kgateway proxy | `envoy_http_downstream_rq_total`, `envoy_cluster_upstream_rq_total` | Gateway ingress traffic rates |
| kgateway ctrl | controller reconcile duration | Reconciliation performance |
| ext-auth | `runtime_goroutines_total` | Auth service health |
| rate-limiter | `runtime_goroutines_total` | Rate limiter health |
| istiod | `pilot_xds_pushes`, `pilot_proxy_convergence_time` | Config push rate, convergence time |
| ztunnel | `istio_tcp_connections_opened_total`, `istio_tcp_sent_bytes_total` | L4 traffic volume |
| gateway (waypoint) | `envoy_http_downstream_rq_total` | L7 request rates |
| gateway (eastwest) | `istio_tcp_connections_opened_total` | Cross-cluster HBONE tunnel traffic |

## Cleanup

```bash
# Primary
helm uninstall opentelemetry-collector -n otel --kube-context $CTX_PRIMARY
kubectl delete namespace otel --context $CTX_PRIMARY

# Secondary
helm uninstall opentelemetry-collector -n otel --kube-context $CTX_SECONDARY
kubectl delete namespace otel --context $CTX_SECONDARY
```

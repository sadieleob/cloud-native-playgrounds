# Multicluster Ambient Mesh — Architecture Overview

## Platform Summary

| Component | Version | Notes |
|---|---|---|
| Kubernetes | v1.32.5 (Kind) | Two clusters: demo-east, demo-west |
| Istio | 1.29.3-solo (ambient) | Solo Enterprise for Istio, no sidecars |
| kgateway | 2.2.4 (Enterprise) | K8s Gateway API, ambient-enrolled |
| Solo UI | 0.4.6 | Management on east, relay on west |
| Trust Domains | `demo-east.local`, `demo-west.local` | Separate CAs, shared root of trust |

---

## Cluster Topology

```
  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │       demo-east             │              │       demo-west             │
  │                             │              │                             │
  │  control-plane + worker     │              │  control-plane + worker     │
  │                             │              │                             │
  │  Trust: demo-east.local     │              │  Trust: demo-west.local     │
  │                             │              │                             │
  │  istio-eastwest gw ◄────────┼── HBONE ─────┼──► istio-eastwest gw       │
  │  (port 15443)               │   (mTLS)     │  (port 15443)              │
  └─────────────────────────────┘              └─────────────────────────────┘
                        │                                │
                        └───── Shared Root CA ────────────┘
```

---

## Namespace Layout

### demo-east (Primary)

| Namespace | Ambient | Purpose | Key Pods |
|---|---|---|---|
| `istio-system` | No | Istio control plane | istiod, ztunnel (DaemonSet), istio-cni (DaemonSet) |
| `istio-eastwest` | No | Cross-cluster gateway | istio-eastwest (LB) |
| `kgateway-system` | **Yes** | API Gateway + N-S ingress | enterprise-kgateway, http (LB), ext-auth-service, rate-limiter, ext-cache, waf-server |
| `nginx` | **Yes** | Demo workload | nginx-service, waypoint proxy |
| `default` | **Yes** | Test clients | curl-client |
| `restricted` | **Yes** | Denied-by-policy client | curl-restricted |
| `otel` | No | External OTel collector | opentelemetry-collector |
| `solo-enterprise` | **No** | Solo UI (management) | ClickHouse, OTel collector, UI (LB), telemetry-gateway (LB) |

### demo-west (Secondary)

| Namespace | Ambient | Purpose | Key Pods |
|---|---|---|---|
| `istio-system` | No | Istio control plane | istiod, ztunnel, istio-cni |
| `istio-eastwest` | No | Cross-cluster gateway | istio-eastwest (LB) |
| `nginx` | **Yes** | Demo workload | nginx-service, waypoint proxy |
| `restricted` | **Yes** | Denied-by-policy client | curl-restricted |
| `otel` | No | External OTel collector | opentelemetry-collector |
| `solo-enterprise` | **No** | Solo UI (relay) | relay, OTel collector |

---

## Data Plane Architecture (Ambient Mode)

```
                          No Sidecars — Zero Injection

  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
  │  App Pod A   │    │  App Pod B   │    │  App Pod C   │
  │ (1 container)│    │ (1 container)│    │ (1 container)│
  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘
         │                   │                   │
  ═══════╪═══════════════════╪═══════════════════╪═══════ iptables redirect
         │                   │                   │
  ┌──────▼───────────────────▼───────────────────▼───────────┐
  │                    ztunnel (DaemonSet)                    │
  │                                                          │
  │  • L4 mTLS (HBONE)        • SPIFFE identity per SA       │
  │  • Transparent intercept   • Cross-cluster tunneling      │
  │  • Zero app changes        • TCP + HTTP/2 multiplexing    │
  └──────────────────────────┬───────────────────────────────┘
                             │
                             │ When L7 policy needed
                             ▼
                ┌──────────────────────────┐
                │   Waypoint Proxy (per-NS) │
                │                            │
                │  • L7 AuthorizationPolicy  │
                │  • Rate limiting            │
                │  • Request routing          │
                │  • Envoy-based              │
                └──────────────────────────────┘
```

### Key Difference from Sidecar Mode

| Aspect | Sidecar | Ambient |
|---|---|---|
| Proxy per pod | 1 sidecar container | 0 (shared ztunnel DaemonSet) |
| Resource overhead | CPU/RAM per pod | CPU/RAM per node |
| L7 policy | Sidecar Envoy | Waypoint proxy (opt-in, per namespace) |
| Pod restart on mesh add | Yes (injection) | No (transparent) |
| SPIFFE identity | Per pod | Per service account |

---

## Traffic Flows

### North-South Ingress (External → Mesh)

```
External Client
      │
      │ HTTP (plaintext)
      ▼
┌─────────────────────────────┐
│ kgateway Proxy (http)       │  LB:8080
│ (kgateway-system)           │  HTTPRoute: nginx.example.com
│                             │  backendRef: nginx-service.nginx.mesh.internal (Hostname)
│ SPIFFE: spiffe://demo-east.local/ns/kgateway-system/sa/http
└─────────────┬───────────────┘
              │ mTLS (HBONE via ztunnel)
              ▼
┌─────────────────────────────┐
│ Waypoint Proxy              │  L7 policy enforcement
│ (nginx namespace)           │  AuthorizationPolicy evaluated here
│                             │
│ SPIFFE: spiffe://demo-east.local/ns/nginx/sa/waypoint
└─────────────┬───────────────┘
              │ mTLS (HBONE via ztunnel)
         ┌────┴────┐
         ▼         ▼
   ┌───────────┐ ┌───────────┐
   │ nginx     │ │ nginx     │
   │ (EAST)    │ │ (WEST)    │  via east-west gateway
   │ us-east-1 │ │ us-west-2 │
   └───────────┘ └───────────┘
```

### East-West (Cross-Cluster Service-to-Service)

```
curl-client (east, default ns)
      │
      │ curl nginx-service.nginx.mesh.internal:8080
      ▼
┌─────────────────────────────┐
│ ztunnel (east)              │  Intercepts outbound, initiates mTLS
│ src: spiffe://demo-east.local/ns/default/sa/curl-client
└─────────────┬───────────────┘
              │
         ┌────┴────────────────────────────┐
         │ Local                           │ Remote (HBONE tunnel)
         ▼                                 ▼
┌────────────────┐              ┌─────────────────────┐
│ Waypoint (east)│              │ istio-eastwest (east)│ LB:15443
└───────┬────────┘              └──────────┬──────────┘
        │                                  │
        ▼                                  ▼
┌────────────────┐              ┌─────────────────────┐
│ nginx (east)   │              │ istio-eastwest (west)│
└────────────────┘              └──────────┬──────────┘
                                           │
                                           ▼
                                ┌────────────────┐
                                │ Waypoint (west)│
                                └───────┬────────┘
                                        │
                                        ▼
                                ┌────────────────┐
                                │ nginx (west)   │
                                └────────────────┘
```

### Global Service Discovery (mesh.internal)

Solo's Istio distribution (1.29.3-solo) includes a custom controller in istiod that automates cross-cluster service discovery. The flow:

**Step 1 — Label the Service**

```bash
kubectl label svc nginx-service -n nginx solo.io/service-scope=global
```

**Step 2 — istiod auto-generates a ServiceEntry**

When istiod detects the `solo.io/service-scope=global` label, it creates a `ServiceEntry` in `istio-system`:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: autogen.nginx.nginx-service    # auto-generated name
  namespace: istio-system
  labels:
    solo.io/parent-service: nginx-service
    solo.io/parent-service-namespace: nginx
    solo.io/service-scope: global
spec:
  hosts:
  - nginx-service.nginx.mesh.internal   # global hostname
  location: MESH_INTERNAL
  ports:
  - name: http
    number: 8080
    protocol: HTTP
  resolution: STATIC
  endpoints:                            # aggregated from ALL clusters
  - address: <east-pod-ip>
    labels: { ... }
  - address: <west-pod-ip>             # discovered via east-west gateway
    labels: { ... }
```

**Step 3 — VIP allocation and DNS**

- `ISTIO_META_DNS_AUTO_ALLOCATE=true` assigns a virtual IP from `240.240.0.0/16` (e.g., `240.240.0.1`)
- `ISTIO_META_DNS_CAPTURE=true` enables ztunnel's transparent DNS proxy
- Any pod in the mesh resolving `nginx-service.nginx.mesh.internal` gets VIP `240.240.0.1`

**Step 4 — ztunnel routes to local or remote endpoints**

```
┌──────────────────────────────────────────────────────────────────────┐
│  nginx-service.nginx.mesh.internal  →  VIP 240.240.0.1              │
│                                                                      │
│  ztunnel endpoint table:                                             │
│    • east: pod IP (direct, local)                                    │
│    • west: pod IP (via east-west gateway HBONE tunnel)               │
│                                                                      │
│  Verify: istioctl ztunnel-config service | grep autogen.nginx        │
│  Expected: autogen.nginx.nginx-service  240.240.0.1  2/2             │
└──────────────────────────────────────────────────────────────────────┘
```

**Key detail:** This is a Solo-specific feature (`solo.io/service-scope` label). Upstream Istio uses `serviceScopeConfigs` in the mesh config with `istio.io/global` label — Solo's distribution uses its own mechanism instead.

---

## Security Architecture

### mTLS (Automatic, Zero-Config)

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Certificate Chain                            │
│                                                                      │
│  Root CA (shared)                                                    │
│    ├── Intermediate CA: demo-east.local                              │
│    │     └── SPIFFE://demo-east.local/ns/{ns}/sa/{sa}                │
│    └── Intermediate CA: demo-west.local                              │
│          └── SPIFFE://demo-west.local/ns/{ns}/sa/{sa}                │
│                                                                      │
│  Cross-cluster trust: Both clusters share root CA (cacerts secret)   │
│  Each cluster has its own trust domain and intermediate CA            │
└──────────────────────────────────────────────────────────────────────┘
```

Every connection shows SPIFFE identities in ztunnel logs:
```
src.identity="spiffe://demo-east.local/ns/kgateway-system/sa/http"
dst.identity="spiffe://demo-west.local/ns/nginx/sa/nginx-service"
```

### Authorization Policies

| Policy | Namespace | Action | Effect |
|---|---|---|---|
| `nginx-default-deny` | nginx | (deny all) | Block all traffic to nginx by default |
| `nginx-allow-default-ns` | nginx | ALLOW | Permit `default` namespace clients |
| `deny-west-restricted` | nginx | DENY | Block `demo-west.local/ns/restricted/sa/default` |

All policies target `kind: Gateway` (waypoint), not `kind: Service`, ensuring enforcement for both `svc.cluster.local` and `mesh.internal` traffic.

Deployed on **both** clusters — waypoints are destination-side enforcement points.

---

## Solo UI Telemetry Pipeline

```
┌──────────────────────────────────────────────────────────────────────┐
│                         demo-east                                    │
│                                                                      │
│  istiod ─────────┐                                                   │
│  ztunnel ────────┤  Prometheus /metrics                              │
│  waypoint ───────┤                                                   │
│  kgateway ───────┘                                                   │
│        │                                                             │
│        ▼                                                             │
│  ┌────────────────────────────────────┐                              │
│  │ OTel Collector (solo-enterprise)   │                              │
│  │ Scrapes Prometheus endpoints       │                              │
│  │ Transforms → ClickHouse inserts    │                              │
│  └──────────────┬─────────────────────┘                              │
│                 │                                                     │
│                 ▼                                                     │
│  ┌────────────────────────────────────┐     ┌──────────────────────┐ │
│  │ ClickHouse (shard0)               │ ◄── │ Solo UI Backend      │ │
│  │ solo-management-clickhouse        │     │ Queries for graph,   │ │
│  │ Stores: metrics, traces           │     │ dashboards, etc.     │ │
│  └────────────────────────────────────┘     └──────────────────────┘ │
│                                                                      │
│        ▲ Telemetry Gateway (LB)                                      │
│        │                                                             │
└────────┼─────────────────────────────────────────────────────────────┘
         │
         │ OTel (gRPC)
         │
┌────────┼─────────────────────────────────────────────────────────────┐
│        │                    demo-west                                 │
│  ┌─────┴──────────────────────────────┐                              │
│  │ OTel Collector (solo-enterprise)   │                              │
│  │ Scrapes local Prometheus endpoints │                              │
│  │ Exports to east telemetry gateway  │                              │
│  └────────────────────────────────────┘                              │
│                                                                      │
│  ┌────────────────────────────────────┐                              │
│  │ Relay (solo-enterprise)            │                              │
│  │ Tunnel client → east UI (9000)     │                              │
│  │ Ships K8s resources to mgmt        │                              │
│  └────────────────────────────────────┘                              │
└──────────────────────────────────────────────────────────────────────┘

IMPORTANT: solo-enterprise namespace must NOT be enrolled in ambient mesh.
ztunnel intercepts ClickHouse (port 9000) and OTel collector (port 4316),
breaking raw TCP protocols.
```

### Solo UI Access

| Method | Command |
|---|---|
| Port-forward | `kubectl port-forward svc/solo-enterprise-ui -n solo-enterprise --context kind-demo-east 8090:80` |
| LoadBalancer | `http://<LB_IP>` |

---

## Failover Architecture

```
                    Normal Operation                       Failover (East Down)
                    ─────────────────                       ────────────────────

  kgateway ──→ mesh.internal VIP              kgateway ──→ mesh.internal VIP
                        │                                           │
                   ┌────┴────┐                              ┌──────┘
                   ▼         ▼                              ▼
              nginx(E)   nginx(W)                       nginx(W)
              endpoint   endpoint                       endpoint
               (local)   (remote)                       (remote only)

  ztunnel endpoints: 2/2                    ztunnel endpoints: 1/1
  Load balanced ~50/50                      100% west, zero downtime

  Recovery: Scale east back up → ztunnel auto-discovers → 2/2 endpoints restored
```

Node locality labels enable locality-aware routing:
- East nodes: `topology.kubernetes.io/region=us-east-1`, `zone=us-east-1a`
- West nodes: `topology.kubernetes.io/region=us-west-2`, `zone=us-west-2a`

---

## Configuration Reference

### Istio Mesh Config (both clusters)

```yaml
accessLogFile: /dev/stdout
defaultConfig:
  proxyMetadata:
    ISTIO_META_DNS_AUTO_ALLOCATE: "true"
    ISTIO_META_DNS_CAPTURE: "true"
    ISTIO_META_ENABLE_HBONE: "true"
serviceScopeConfigs:
  - scope: GLOBAL
    servicesSelector:
      matchExpressions:
        - key: istio.io/global
          operator: In
          values: ["true"]
```

### K8s Gateway API Resources (East)

| Resource | Namespace | Purpose |
|---|---|---|
| Gateway `http` | kgateway-system | N-S ingress (kgateway) |
| Gateway `istio-eastwest` | istio-eastwest | Cross-cluster HBONE tunnel |
| Gateway `waypoint` | nginx | L7 policy enforcement |
| HTTPRoute `nginx-ingress` | kgateway-system | Routes `nginx.example.com` → `mesh.internal` |

---

## Known Limitations

### kgateway Proxy Not Visible in Solo UI Graph

The kgateway proxy (`http`) does not emit `istio_requests_total` (it is not an Istio sidecar/waypoint). The Solo UI service graph only shows edges from Istio-emitted metrics. Consequences:

- **No inbound edge** for external N-S traffic entering the kgateway proxy
- **Outbound edge** (kgateway → waypoint) is visible only via ztunnel source-reported metrics
- **"No data" in detail panel** — the workload detail queries destination-reported metrics which don't exist for the kgateway proxy
- **showInfrastructureHops** default (false) hides the kgateway proxy since it has a `gateway_api_label`
- **Workaround**: Enable "Show Unregistered External Services" toggle in the UI to surface the proxy

---

## Documentation Index

| Doc | Purpose |
|---|---|
| `00_setup.md` | Environment setup, Kind clusters, certs |
| `01_install_ambient.md` | Istio 1.29.3-solo ambient + multicluster install |
| `02_install_kgateway.md` | Enterprise kgateway 2.2.4 install |
| `03_deploy_apps.md` | nginx, curl-client, global service labels |
| `04_demo_policies.md` | Waypoint + AuthorizationPolicies |
| `05_kgateway_ingress.md` | kgateway N-S ingress + ambient mesh.internal |
| `06_failover.md` | Cross-cluster failover demo |
| `07_architecture.md` | This document |
| `08_comparison_kgateway_vs_ggv1_ambient.md` | kgateway vs GGv1 for ambient mesh |
| `09_otel_collector.md` | External OTel Collector for custom telemetry |
| `10_solo_ui.md` | Solo UI 0.4.6 deployment guide |

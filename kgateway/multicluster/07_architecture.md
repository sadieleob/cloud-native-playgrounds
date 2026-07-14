# Architecture Overview

## Component Versions

| Component | Version | Notes |
|---|---|---|
| Kubernetes | v1.32.5 (Kind) | Two clusters: demo-east, demo-west |
| Istio | 1.29.3-solo (ambient) | Solo Enterprise for Istio, no sidecars |
| KGateway | 2.2.4 (Enterprise) | K8s Gateway API, ambient-enrolled, east only |
| Gateway API CRDs | v1.5.1 | Required by kgateway 2.2.x |
| Trust Domains | `demo-east.local`, `demo-west.local` | Separate CAs, shared root of trust |

## Cluster Topology

```
  ┌─────────────────────────────┐              ┌─────────────────────────────┐
  │       demo-east          │              │       demo-west          │
  │                             │              │                             │
  │  control-plane + worker     │              │  control-plane + worker     │
  │                             │              │                             │
  │  Trust: demo-east.local  │              │  Trust: demo-west.local  │
  │                             │              │                             │
  │  istio-eastwest gw ◄────────┼── HBONE ─────┼──► istio-eastwest gw       │
  │  (port 15443)               │   (mTLS)     │  (port 15443)              │
  └─────────────────────────────┘              └─────────────────────────────┘
                        │                                │
                        └───── Shared Root CA ────────────┘
```

## Namespace Layout

### demo-east (Primary)

| Namespace | Ambient | Purpose | Key Pods |
|---|---|---|---|
| `istio-system` | No | Istio control plane | istiod, ztunnel (DaemonSet), istio-cni (DaemonSet) |
| `istio-eastwest` | No | Cross-cluster gateway | istio-eastwest (LB) |
| `kgateway-system` | **Yes** | KGateway N-S ingress | enterprise-kgateway controller, http proxy pod (LB) |
| `nginx` | **Yes** | Demo workload | nginx-service, waypoint proxy |
| `default` | **Yes** | Test clients | curl-client |
| `restricted` | **Yes** | Denied-by-policy client | curl-restricted |

### demo-west (Secondary)

| Namespace | Ambient | Purpose | Key Pods |
|---|---|---|---|
| `istio-system` | No | Istio control plane | istiod, ztunnel, istio-cni |
| `istio-eastwest` | No | Cross-cluster gateway | istio-eastwest (LB) |
| `nginx` | **Yes** | Demo workload | nginx-service, waypoint proxy |
| `default` | **Yes** | Test clients | curl-client |
| `restricted` | **Yes** | Denied-by-policy client | curl-restricted |

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
  └──────────────────────────┬───────────────────────────────┘
                             │ (when L7 policy needed)
                    ┌────────▼────────┐
                    │ Waypoint Proxy   │
                    │ (per-namespace)   │
                    │                  │
                    │ • L7 AuthZ       │
                    │ • Rate limiting  │
                    │ • Observability  │
                    └──────────────────┘
```

## N-S Traffic Flow

```
External Client
      | (plaintext HTTP)
      v
+---------------------+
| KGateway Proxy      |  SA: http (kgateway-system)
| [bypass-inbound]    |  External inbound NOT captured by ztunnel
+---------+-----------+
          | outbound captured by ztunnel → mTLS (HBONE)
          v
+---------------------+
| Waypoint Proxy      |  SA: waypoint (nginx ns)
| (nginx namespace)   |  AuthZ policies evaluated here
+---------+-----------+
          | mTLS (ztunnel → HBONE)
     +----+----+
     v         v
+---------+ +---------+
| nginx   | | nginx   |
| (EAST)  | | (WEST)  |  via EW gateway when cross-cluster
+---------+ +---------+
```

## E-W Traffic Flow (Cross-Cluster)

```
curl-client (default ns, east)
      | captured by ztunnel
      v
+---------------------+
| ztunnel (east)      |  src: spiffe://demo-east.local/ns/default/sa/curl-client
+---------+-----------+
          | HBONE tunnel
          v
+---------------------+
| EW Gateway (east)   |  port 15443
+---------+-----------+
          | HBONE over Docker network
          v
+---------------------+
| EW Gateway (west)   |  port 15443
+---------+-----------+
          | HBONE
          v
+---------------------+
| ztunnel (west)      |
+---------+-----------+
          | → waypoint (if attached)
          v
+---------------------+
| nginx (west)        |  dst: spiffe://demo-west.local/ns/nginx/sa/nginx-service
+---------------------+
```

## Security Model

- **Shared Root CA** with per-cluster intermediate certificates (EasyRSA)
- **SPIFFE identities** per service account: `spiffe://<trustDomain>/ns/<ns>/sa/<sa>`
- **PeerAuthentication STRICT** blocks non-mesh traffic
- **bypass-inbound-capture** on kgateway proxy: ztunnel captures outbound only, so external clients (no mesh identity) can still reach the gateway
- **AuthorizationPolicies** on waypoint: default-deny + explicit allow by namespace/identity

## Files Reference

| File | Purpose |
|---|---|
| `manifests/nginx-east.yaml` | Nginx deployment for east cluster |
| `manifests/nginx-west.yaml` | Nginx deployment for west cluster |
| `manifests/curl-client.yaml` | Curl client for testing |
| `manifests/waypoint.yaml` | Waypoint proxy (L7 enforcement) |
| `manifests/authz-policies.yaml` | AuthorizationPolicies |
| `manifests/kgateway-params.yaml` | EnterpriseKgatewayParameters (bypass-inbound-capture) |
| `manifests/kgateway-gateway.yaml` | KGateway Gateway resource |
| `manifests/httproute-nginx.yaml` | HTTPRoute with mesh.internal backendRef |

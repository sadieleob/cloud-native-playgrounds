# Kgateway Enterprise 2.2.4 vs Gloo Gateway v1 1.20.x — Ambient Mesh Integration Comparison

This document compares the documented setup procedures, architecture, and operational differences between **Solo Enterprise for Kgateway 2.2.4** and **Gloo Gateway v1 1.20.x** when integrated with Istio Ambient mesh. Both single-cluster and multicluster scenarios are covered.

**Sources:**
- Kgateway 2.2.x: [docs.solo.io/kgateway/2.2.x/integrations/istio/ambient/](https://docs.solo.io/kgateway/2.2.x/integrations/istio/ambient/)
- GGv1 1.20.x: [docs.solo.io/gateway/1.20.x/setup/deployment-patterns/ambient/](https://docs.solo.io/gateway/1.20.x/setup/deployment-patterns/ambient/)
- Demo lab: this directory's `00_setup.md` through `07_architecture.md`

---

## 1. Architecture Comparison

| Dimension | Kgateway Enterprise 2.2.4 | Gloo Gateway v1 1.20.x |
|---|---|---|
| **Control plane** | `enterprise-kgateway` controller | `gloo` control plane (translator + discovery) |
| **Default namespace** | `kgateway-system` | `gloo-system` |
| **Proxy pod (ambient)** | Single container (Envoy) | Single container (Envoy) |
| **Proxy pod (sidecar)** | Single container + SDS | 3 containers: `gateway-proxy`, `istio-proxy`, `sds` |
| **API model** | Kubernetes Gateway API only (HTTPRoute, Gateway) | Gateway API + proprietary Gloo APIs (VirtualService, Upstream) |
| **GatewayClass** | `enterprise-kgateway` | `gloo-gateway` |
| **CRD API groups** | `gateway.kgateway.dev`, `enterprisekgateway.solo.io` | `gateway.solo.io`, `gloo.solo.io`, `enterprise.gloo.solo.io` |
| **Helm charts** | OCI: `enterprise-kgateway-crds` + `enterprise-kgateway` | `glooe/gloo-ee` (single chart) |
| **Product status** | Active development | Maintenance mode |

### Key takeaway
In ambient mode, both products run a single-container Envoy proxy pod (no sidecar injection). The architectural difference is in the control plane and API surface, not the data path.

---

## 2. Enabling the Istio Integration

### Kgateway Enterprise

A single environment variable on the controller. This makes kgateway watch `ServiceEntry` resources so `kind: Hostname` backendRefs can resolve `mesh.internal` global hostnames.

```yaml
# Helm values
controller:
  extraEnv:
    KGW_ENABLE_ISTIO_INTEGRATION: true
```

```bash
helm upgrade -i enterprise-kgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
  -n kgateway-system \
  --version 2.2.4 \
  --set-string licensing.licenseKey=$GLOO_GATEWAY_LICENSE_KEY \
  --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true
```

### GGv1 — Single Cluster

No special Helm values needed. Just label the `gloo-system` namespace for ambient and it works.

### GGv1 — Multicluster

Requires an environment variable on the `gloo` deployment:

```yaml
# Helm values
gloo:
  gloo:
    deployment:
      customEnv:
        - name: GG_AMBIENT_MULTINETWORK
          value: "true"
```

```bash
helm upgrade -n gloo-system gloo glooe/gloo-ee \
  -f gloo-gateway.yaml \
  --version=1.20.16
```

### Diff

| What | Kgateway | GGv1 |
|---|---|---|
| Single-cluster flag | `KGW_ENABLE_ISTIO_INTEGRATION=true` (required) | None (just label the namespace) |
| Multicluster flag | Same flag covers both | `GG_AMBIENT_MULTINETWORK=true` (additional) |
| Where the flag lives | Helm `controller.extraEnv` | Helm `gloo.gloo.deployment.customEnv` |
| Separate CRD chart | Yes (`enterprise-kgateway-crds`) | No (CRDs bundled in main chart) |

---

## 3. Enrolling in the Ambient Mesh

**Identical for both products.** Label the gateway namespace:

```bash
# Kgateway
kubectl label ns kgateway-system istio.io/dataplane-mode=ambient

# GGv1
kubectl label ns gloo-system istio.io/dataplane-mode=ambient
```

And label app namespaces:

```bash
kubectl label ns httpbin istio.io/dataplane-mode=ambient
```

No sidecars injected. Ztunnel intercepts outbound traffic from the gateway proxy and wraps it in mTLS via HBONE.

---

## 4. PeerAuthentication STRICT Mode Handling

**Same gotcha, same fix for both products.**

When the gateway namespace is ambient-enrolled, ztunnel captures both inbound and outbound traffic. With `mtls.mode: STRICT`, external clients (no mesh identity) get rejected:

```
connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict
```

### Fix: Bypass inbound capture

Both products use `EnterpriseKgatewayParameters` with the `ambient.istio.io/bypass-inbound-capture: "true"` annotation:

```yaml
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayParameters
metadata:
  name: kgw-ambient-params
  namespace: kgateway-system   # or gloo-system for GGv1
spec:
  kube:
    podTemplate:
      extraAnnotations:
        ambient.istio.io/bypass-inbound-capture: "true"
```

### Kgateway — Gateway references the params

Kgateway requires an explicit `infrastructure.parametersRef` on the Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: http
  namespace: kgateway-system
spec:
  gatewayClassName: enterprise-kgateway
  infrastructure:
    parametersRef:
      name: kgw-ambient-params
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
```

### GGv1 — GatewayParameters via Helm

GGv1's `GatewayParameters` resource is created by Helm. The annotation can be added via the Helm values `kubeGateway.gatewayParameters` or by patching the auto-generated `GatewayParameters` resource.

### Diff

| What | Kgateway | GGv1 |
|---|---|---|
| Params CRD | `EnterpriseKgatewayParameters` (`enterprisekgateway.solo.io`) | `GatewayParameters` (`gateway.gloo.solo.io/v1alpha1`) |
| How Gateway references it | `infrastructure.parametersRef` on Gateway spec | Auto-wired by Helm, or manual GatewayParameters |
| When it's needed | Always (if PeerAuth STRICT is enabled) | Same |

---

## 5. Multicluster Routing

### HTTPRoute with Global Hostname

**Identical syntax for both products.** The `kind: Hostname` backendRef with `group: networking.istio.io` routes to the auto-generated ServiceEntry:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-ingress
  namespace: kgateway-system   # or gloo-system for GGv1
spec:
  parentRefs:
  - name: http
    namespace: kgateway-system  # or gloo-system
  rules:
  - backendRefs:
    - name: nginx-service.nginx.mesh.internal
      port: 8080
      kind: Hostname
      group: networking.istio.io
```

### Hostname format

| Segments configured | Format |
|---|---|
| No | `<svc>.<namespace>.mesh.internal` |
| Yes | `<svc>.<namespace>.<segment_domain>` |

### Port mapping

The `port` value must match the Kubernetes `Service.port`, not the container `targetPort`.

**Known issue (both products):** In Solo Istio before 1.29.2-patch0 (1.29.x) and 1.28.6 (1.28.x), named `targetPort` values (e.g., `targetPort: http`) are not correctly resolved. Workaround: use numeric `targetPort`.

### GGv1 multicluster enablement

GGv1 requires `GG_AMBIENT_MULTINETWORK=true`:

```yaml
gloo:
  gloo:
    deployment:
      customEnv:
        - name: GG_AMBIENT_MULTINETWORK
          value: "true"
```

### Kgateway multicluster enablement

Kgateway uses the same `KGW_ENABLE_ISTIO_INTEGRATION=true` flag — no additional multicluster-specific flag.

### Waypoint routing

Both products support routing ingress traffic through waypoint proxies via the same label on the destination service:

```bash
kubectl label svc nginx-service -n nginx istio.io/ingress-use-waypoint=true
```

Without this label, kgateway (and GGv1) route directly to the pod, bypassing the waypoint.

---

## 6. N-S vs E-W Failover Behavior

**Same behavior for both products** — this is an ambient mesh characteristic, not gateway-specific.

| Path | Failover trigger | Behavior |
|---|---|---|
| **E-W (pod-to-pod via ztunnel)** | Pod `NotReady` | ztunnel detects unhealthy pods and routes to cross-cluster endpoints |
| **N-S (gateway ingress)** | All local pods scaled to zero | kgateway/GGv1 resolves `mesh.internal` to a ServiceEntry VIP. Cross-cluster failover only triggers when no local endpoints exist. `NotReady` pods still receive N-S traffic. |

### Implication
N-S ingress failover is coarser than E-W. For fine-grained N-S failover based on pod health, use DestinationRule-based outlier detection (documented in the Solo Istio ambient failover guide).

---

## 7. Policy Model — The Core Difference

This is where the two products diverge most. The ambient mesh integration (ztunnel, mTLS, waypoints) is identical, but the gateway-level traffic policies use entirely different CRD APIs.

| Concern | Kgateway 2.2.4 | GGv1 1.20.x |
|---|---|---|
| **N-S traffic policy** | `EnterpriseKgatewayTrafficPolicy` (EKTP) | `RouteOption` / `VirtualHostOption` |
| **Listener config** | `ListenerPolicy` | `HttpListenerOption` |
| **Backend resilience** | `BackendConfigPolicy` (same-namespace only) | `RouteOption` (retry, timeout fields) |
| **External auth** | `AuthConfig` (`extauth.solo.io`) — auto-deployed SharedExtension | `AuthConfig` (`enterprise.gloo.solo.io`) — Helm-deployed |
| **Rate limiting** | `RateLimitConfig` — auto-deployed SharedExtension | `RateLimitConfig` — Helm-deployed |
| **Gateway parameters** | `EnterpriseKgatewayParameters` | `GatewayParameters` (`gateway.gloo.solo.io`) |
| **Upstream abstraction** | Not applicable (use K8s Services + Backend CRD) | `Upstream` / `UpstreamGroup` CRDs |

### Key operational differences

| Feature | Kgateway | GGv1 |
|---|---|---|
| **ExtAuth/RateLimiter deployment** | Auto-deployed by controller as SharedExtensions when Gateway is created | Deployed by Helm chart — requires explicit Helm values |
| **Policy attachment** | Gateway API `targetRef` / `parentRef` on EKTP | `targetRef` on RouteOption/VirtualHostOption |
| **Admission webhook** | None — eventual consistency model, status reflects issues | Validating webhook rejects invalid resources |
| **WASM support** | No | Yes (via Envoy WASM filters) |
| **WAF** | Enterprise WAFPolicy (2.2+) | Enterprise WAF (RouteOption) |
| **Transformation** | Rustformation engine (EKTP `transformation` field) | Inja templates (RouteOption `transformations`) |

---

## 8. Observability (Ambient Context)

| Feature | Kgateway | GGv1 |
|---|---|---|
| **Solo UI** | Supported (install separately) | Built-in with `gloo-mesh-ui` chart |
| **Ambient mTLS graph** | Via Solo UI (needs separate install) | Built-in: Gloo UI Graph shows lock icons for mTLS connections |
| **Prometheus metrics** | `istio_requests_total` from ztunnel/waypoint (standard Istio) | Same + custom `gloo_gateway_upstream_rq` from OTel pipeline |
| **mTLS verification** | ztunnel logs (SPIFFE identities) | ztunnel logs + Gloo UI + Prometheus expression browser |
| **Service graph** | Solo UI Observability > Graph | Gloo UI Observability > Graph |

GGv1 has a more mature telemetry pipeline for ambient traffic visualization out of the box. Kgateway can achieve the same with a separate Solo UI install.

---

## 9. Sidecar Integration Comparison (Not Ambient)

For completeness — when using sidecar mode instead of ambient:

### Kgateway (sidecar mode)

```yaml
controller:
  extraEnv:
    KGW_ENABLE_ISTIO_INTEGRATION: true
```

Plus `GatewayParameters` with `istioProxyContainer` settings if using revisioned istiod:

```yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: GatewayParameters
spec:
  kube:
    istio:
      istioProxyContainer:
        istioDiscoveryAddress: istiod-1-27.istio-system.svc:15012
        istioMetaClusterId: mycluster
        istioMetaMeshId: mycluster
    sdsContainer:
      image:
        registry: cr.kgateway.dev/kgateway-dev
        repository: sds
```

### GGv1 (sidecar mode)

```yaml
global:
  istioIntegration:
    enableAutoMtls: true
    enabled: true
  istioSDS:
    enabled: true
kubeGateway:
  gatewayParameters:
    glooGateway:
      istio:
        istioProxyContainer:
          istioDiscoveryAddress: istiod-1-27.istio-system.svc:15012
          istioMetaClusterId: mycluster
          istioMetaMeshId: mycluster
```

### Diff in sidecar mode

| What | Kgateway | GGv1 |
|---|---|---|
| **Containers in pod** | 1 (Envoy) + SDS sidecar | 3: `gateway-proxy`, `istio-proxy`, `sds` |
| **Sidecar injection** | Via GatewayParameters | Via Helm `istioIntegration` + `istioSDS` values |
| **Istio discovery config** | `GatewayParameters.spec.kube.istio` | `kubeGateway.gatewayParameters.glooGateway.istio` |

---

## 10. Full Setup Procedure — Side by Side

### Single Cluster Ambient

| Step | Kgateway 2.2.4 | GGv1 1.20.x |
|---|---|---|
| 1. Install gateway | `helm upgrade -i enterprise-kgateway-crds ...` + `helm upgrade -i enterprise-kgateway ... --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true` | `helm upgrade -i gloo glooe/gloo-ee ...` (no special flags for single-cluster ambient) |
| 2. Install Istio ambient | Solo Istio via Gloo Operator or manual Helm | Same |
| 3. Create EnterpriseKgatewayParameters | Required if PeerAuth STRICT | Same (different API group) |
| 4. Create Gateway | `spec.infrastructure.parametersRef` references params | Auto-created by Helm or manual |
| 5. Label gateway namespace | `kubectl label ns kgateway-system istio.io/dataplane-mode=ambient` | `kubectl label ns gloo-system istio.io/dataplane-mode=ambient` |
| 6. Label app namespaces | `kubectl label ns httpbin istio.io/dataplane-mode=ambient` | Same |
| 7. Create HTTPRoute | Standard Gateway API HTTPRoute | Same |
| 8. Verify mTLS | Check ztunnel logs for SPIFFE identities | Same + Gloo UI graph |

### Multicluster Ambient

| Step | Kgateway 2.2.4 | GGv1 1.20.x |
|---|---|---|
| 1. Install Istio ambient (both clusters) | Solo Istio with peering chart | Same |
| 2. Install gateway (primary cluster) | `KGW_ENABLE_ISTIO_INTEGRATION=true` | `GG_AMBIENT_MULTINETWORK=true` |
| 3. Label gateway ns for ambient | `kubectl label ns kgateway-system istio.io/dataplane-mode=ambient` | `kubectl label ns gloo-system istio.io/dataplane-mode=ambient` |
| 4. Create HTTPRoute with global hostname | `backendRefs: [{name: svc.ns.mesh.internal, kind: Hostname, group: networking.istio.io}]` | Same |
| 5. Deploy waypoint (both clusters) | Istio `gateway.networking.k8s.io/v1` with `istio-waypoint` class | Same |
| 6. Label service for waypoint routing | `istio.io/ingress-use-waypoint=true` | Same |
| 7. Apply AuthorizationPolicies | Target waypoint Gateway for cross-cluster coverage | Same |
| 8. Test failover | Scale local pods to 0, verify traffic routes cross-cluster | Same |

---

## 11. Summary — When to Use Which

| Scenario | Recommendation |
|---|---|
| **New deployment** | Kgateway Enterprise — active development, simpler API surface, SharedExtensions |
| **Existing GGv1 + ambient already working** | Stay on GGv1 until planned migration — ambient integration itself doesn't change |
| **Need dual API (VirtualService + HTTPRoute)** | GGv1 — supports both simultaneously during migration |
| **Need WASM filters** | GGv1 — kgateway v2 does not support WASM |
| **Need single unified policy type** | Kgateway — EKTP covers traffic, auth, rate limiting in one CRD |
| **GitOps-first (ArgoCD/Flux)** | Kgateway — fewer CRDs, cleaner Gateway API alignment |

### Bottom line

For **ambient mesh integration specifically**, both products are functionally identical — same namespace labeling, same ztunnel mTLS, same PeerAuth bypass annotation, same multicluster `mesh.internal` routing, same waypoint integration, same failover behavior. The differences are entirely in the **gateway control plane** (CRD APIs, policy model, Helm chart structure, operational tooling).

If you're evaluating which product to deploy alongside ambient, the decision should be based on the gateway policy requirements and long-term product direction — not the ambient integration itself, which is a shared capability.

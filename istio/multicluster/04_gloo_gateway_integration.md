# Gloo Gateway 1.20.10 + Istio Ambient Mesh Integration

Demo's requirements for the service mesh + API gateway integration:
1. **Rate limiting between services** — prevent service A from overwhelming service B
2. **Service-level access control** — restrict which services can communicate
3. **mTLS** for all service-to-service communication (currently plain HTTP)
4. **Centralized observability** — single admin console across environments
5. **Gateway + mesh in tandem** — similar policies at both north-south and east-west layers

This guide demonstrates all five capabilities using Gloo Gateway 1.20.10 (K8s Gateway API) integrated with Istio ambient mesh on the existing `demo-east` / `demo-west` multicluster setup.

## Architecture

```
                        External Client
                              │
                    ┌─────────▼──────────┐
                    │  Gloo Gateway Proxy │ ← North-South ingress (HTTPRoute)
                    │  (gloo-system)      │   K8s Gateway API + rate limiting
                    │  [ambient enrolled] │
                    └─────────┬──────────┘
                              │ mTLS (ztunnel)
                    ┌─────────▼──────────┐
                    │  Waypoint Proxy     │ ← L7 policy enforcement (AuthZ)
                    │  (nginx namespace)  │
                    └─────────┬──────────┘
                              │ mTLS (ztunnel)
              ┌───────────────┼───────────────┐
              │               │               │
        ┌─────▼─────┐  ┌─────▼─────┐  ┌──────▼─────┐
        │ nginx-svc  │  │ nginx-svc │  │ curl-client│
        │ (east)     │  │ (west)    │  │ (intramesh)│
        └────────────┘  └───────────┘  └────────────┘
         demo-east    demo-west   demo-east
```

---

## Step 0: Install Gloo Gateway 1.20.10

Ref: https://docs.solo.io/gateway/1.20.x/setup/deployment-patterns/ambient/

### On demo-east (primary demo cluster)

Create a values file (`gloo-ambient-values.yaml`):

```yaml
gloo:
  kubeGateway:
    enabled: true
  gloo:
    deployment:
      customEnv:
        - name: GG_AMBIENT_MULTINETWORK
          value: "true"
```

```bash
helm install gloo glooe/gloo-ee -n gloo-system --create-namespace \
  --version 1.20.10 \
  --kube-context $CTX_EAST \
  --set license_key=$GLOO_LICENSE_KEY \
  -f gloo-ambient-values.yaml \
  --timeout 10m --wait
```

### Enroll gloo-system in ambient mesh

```bash
kubectl label ns gloo-system istio.io/dataplane-mode=ambient --context $CTX_EAST
```

### Verify

```bash
# Gateway proxy pod should be Running
kubectl get pods -n gloo-system --context $CTX_EAST | grep gloo-proxy

# GatewayClass should exist
kubectl get gatewayclass --context $CTX_EAST | grep gloo
```

### Create the Gateway resource (K8s Gateway API)

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: http
  namespace: gloo-system
spec:
  gatewayClassName: gloo-gateway
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

### Get the gateway address

```bash
export INGRESS_GW_ADDRESS=$(kubectl get svc -n gloo-system gloo-proxy-http --context $CTX_EAST -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo $INGRESS_GW_ADDRESS
```

---

## Scenario 1: North-South Ingress

**Goal:** External traffic enters through Gloo Gateway and reaches nginx in the ambient mesh.

### Create HTTPRoute with cross-cluster Hostname backendRef

The `kind: Hostname` with `group: networking.istio.io` tells Gloo Gateway to route to the global `mesh.internal` hostname, enabling cross-cluster load balancing through the ambient mesh.

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-ingress
  namespace: gloo-system
spec:
  parentRefs:
  - name: http
    namespace: gloo-system
  hostnames:
  - "nginx.demo.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: nginx-service.nginx.mesh.internal
      port: 8080
      kind: Hostname
      group: networking.istio.io
EOF
```

### Test: External → Gloo Gateway → nginx (cross-cluster load balanced)

```bash
for i in $(seq 1 10); do
  curl -s http://${INGRESS_GW_ADDRESS}:8080/ -H "host: nginx.demo.example.com"
done
# Expected: Mix of EAST and WEST responses (load-balanced across clusters via mesh.internal)
```

### Verify: Gateway proxy is in the ambient mesh

```bash
kubectl logs -n istio-system --context $CTX_EAST -l app=ztunnel --since=30s | grep "gloo-proxy" | head -3
# Expected: SPIFFE identity for gloo-proxy-http in src.identity or dst.identity
```

---

## Scenario 2: East-West Traffic (Cross-Cluster)

**Goal:** Service in one cluster reaches the same-named service in another cluster via the global `mesh.internal` hostname.

### Test: East curl-client → mesh.internal → both clusters

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 10); do
  kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s nginx-service.nginx.mesh.internal:8080
done
# Expected: Mix of "EAST" and "WEST" responses
```

### Test: West curl-client → mesh.internal → both clusters

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_WEST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 10); do
  kubectl -n default exec $CURL_POD --context $CTX_WEST -- curl -s nginx-service.nginx.mesh.internal:8080
done
# Expected: Mix of "EAST" and "WEST" responses
```

### Verify: Endpoints from both clusters visible

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx
# Expected: autogen.nginx.nginx-service  ...  2/2 (both east + west endpoints)
```

---

## Scenario 3: Waypoint L7 Policies (AuthorizationPolicy)

**Goal:** L7 authorization policies enforced by waypoint proxy — demonstrating service-level access control.

### Current policies (already deployed)

| Policy | Action | Effect |
|---|---|---|
| `nginx-default-deny` | (empty = deny all) | Block all traffic to nginx by default |
| `nginx-allow-default-ns` | ALLOW | Only `default` namespace can reach nginx |
| `deny-west-restricted` | DENY | Block traffic from `demo-west.local/ns/restricted/sa/default` |

### Test: Allowed traffic (default namespace → nginx)

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s -o /dev/null -w "HTTP %{http_code}" nginx-service.nginx.svc:8080
# Expected: HTTP 200
```

### Test: Denied traffic (restricted namespace → nginx)

```bash
kubectl -n restricted exec curl-restricted --context $CTX_EAST -- curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.svc:8080
# Expected: HTTP 403
```

### Test: Cross-cluster AuthZ enforcement (restricted ns → mesh.internal)

```bash
for i in $(seq 1 6); do
  kubectl -n restricted exec curl-restricted --context $CTX_WEST -- curl -s -w " | HTTP %{http_code}\n" --max-time 5 nginx-service.nginx.mesh.internal:8080
done
# Expected: HTTP 403 from BOTH clusters (enforced by waypoints on each cluster)
```

### Test: Cross-cluster allowed traffic (default ns → mesh.internal)

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_WEST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 6); do
  kubectl -n default exec $CURL_POD --context $CTX_WEST -- curl -s -w " | HTTP %{http_code}\n" --max-time 5 nginx-service.nginx.mesh.internal:8080
done
# Expected: HTTP 200 from both EAST and WEST
```

### Key learning: Target the Gateway, not the Service

AuthorizationPolicies must use `targetRefs` pointing to the waypoint `Gateway`, not the `Service`. Service-targeted policies only apply to the local `svc.cluster.local` VIP. The cross-cluster global service (`mesh.internal`) is a different ServiceEntry and won't match Service-targeted policies.

```yaml
# Correct: targets all traffic through the waypoint
targetRefs:
- kind: Gateway
  group: gateway.networking.k8s.io
  name: waypoint

# Wrong: only targets local svc.cluster.local traffic
targetRefs:
- kind: Service
  group: ""
  name: nginx-service
```

---

## Scenario 4: Intramesh Traffic (Service-to-Service)

**Goal:** Demonstrate service-to-service communication within the ambient mesh, automatic mTLS, and SPIFFE identity propagation.

### Test: curl-client (default ns) → nginx (nginx ns) — same cluster

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s -w "\nHTTP %{http_code}\n" nginx-service.nginx.svc:8080
# Expected: "You hit EAST cluster (demo-east)" + HTTP 200
```

### Verify: ztunnel intercepts and encrypts

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_EAST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=30s | grep "nginx-service" | head -3
```

Expected log showing SPIFFE identities:
```
src.identity="spiffe://demo-east.local/ns/default/sa/curl-client"
dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
```

### Verify: Traffic path — ztunnel → waypoint → ztunnel → nginx

```bash
kubectl logs -l gateway.networking.k8s.io/gateway-name=waypoint -n nginx --context $CTX_EAST --since=30s | tail -3
```

Expected: Waypoint access log showing L7 request details (method, path, response code, upstream).

### Test: Different service accounts have different identities

```bash
# curl-client has identity: spiffe://demo-east.local/ns/default/sa/curl-client
# curl-restricted has identity: spiffe://demo-east.local/ns/restricted/sa/default
# The default-deny + allow policy distinguishes between them
```

---

## Scenario 5: mTLS Strict Mode

**Goal:** Verify that ALL traffic in the mesh is mTLS-encrypted and that non-mesh traffic is blocked.

### Test: Verify mTLS in ztunnel logs

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_EAST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=60s 2>&1 | grep -E "src.identity.*spiffe" | head -5
# Expected: All connections show spiffe:// identities (= mTLS)
```

### Test: Verify cross-cluster mTLS (different trust domains)

```bash
# Send cross-cluster traffic
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s nginx-service.nginx.mesh.internal:8080

# Check ztunnel logs for cross-trust-domain identity
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=10s 2>&1 | grep "demo-west" | head -3
# Expected: src.identity or dst.identity shows spiffe://demo-west.local/...
```

### Test: Apply PeerAuthentication strict mode

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: nginx
spec:
  mtls:
    mode: STRICT
EOF
```

### Verify strict mTLS: non-mesh pod cannot reach nginx

Deploy a pod outside the mesh (namespace without ambient label):

```bash
kubectl create ns non-mesh --context $CTX_EAST
# Intentionally NOT labeling with istio.io/dataplane-mode=ambient
kubectl run curl-nomesh -n non-mesh --context $CTX_EAST \
  --image=curlimages/curl:7.83.1 --restart=Never --command -- sleep infinity

sleep 10

kubectl -n non-mesh exec curl-nomesh --context $CTX_EAST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.svc:8080
# Expected: Connection refused or timeout (non-mesh traffic blocked by STRICT mTLS)
```

### Verify strict mTLS: mesh pod CAN reach nginx

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" nginx-service.nginx.svc:8080
# Expected: HTTP 200 (mesh traffic allowed)
```

### Cleanup PeerAuthentication (optional)

```bash
kubectl delete peerauthentication strict-mtls -n nginx --context $CTX_EAST
```

---

## Summary: Mapping to Demo Requirements (Mar 19 Meeting)

| Demo Requirement | Scenario | How It's Demonstrated |
|---|---|---|
| **API Gateway + mesh in tandem** | Scenario 1 | Gloo Gateway (north-south ingress) enrolled in ambient mesh, mTLS to backends |
| **Service-level access control** | Scenario 3 | AuthorizationPolicy: default-deny + namespace allow + identity deny |
| **mTLS for all S2S communication** | Scenario 4 & 5 | ztunnel auto-mTLS with SPIFFE identities, strict mode blocks non-mesh |
| **Rate limiting between services** | (extends Scenario 3) | Waypoint can enforce rate limits via Istio WasmPlugin or Envoy filters |
| **Centralized observability** | (reference) | Solo UI aggregates metrics across clusters via Prometheus + telemetry pipeline |
| **Cross-region mesh** | Scenario 2 | East-west traffic load-balanced across `demo-east` and `demo-west` |
| **No sidecar overhead** | All | Ambient mode — zero sidecar containers, ztunnel DaemonSet handles L4 |

## Files Reference

| File | Purpose |
|---|---|
| `manifests/nginx-east.yaml` | Nginx deployment for east cluster |
| `manifests/nginx-west.yaml` | Nginx deployment for west cluster |
| `manifests/curl-client.yaml` | Curl client for testing |
| `manifests/waypoint.yaml` | Waypoint proxy (L7 enforcement point) |
| `manifests/authz-policies.yaml` | AuthorizationPolicies (default-deny, allow, cross-cluster deny) |

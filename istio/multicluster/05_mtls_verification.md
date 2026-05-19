# mTLS Verification Tests

Demonstrates strict mTLS enforcement in the ambient mesh by testing connectivity from three perspectives:
1. **Outside the mesh** — a pod in a non-ambient namespace (should be BLOCKED)
2. **Inside the mesh** — a pod enrolled in ambient (should SUCCEED with mTLS)
3. **Cross-cluster but outside the mesh** — verifying mesh boundaries apply globally

## Prerequisites

```bash
export CTX_EAST=kind-demo-east
export CTX_WEST=kind-demo-west
```

Ensure PeerAuthentication STRICT is applied to the nginx namespace:

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

kubectl apply --context $CTX_WEST -f- <<'EOF'
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

---

## Test 1: Client OUTSIDE the mesh (non-ambient namespace)

Create a namespace without the ambient label and deploy a curl pod:

```bash
kubectl create ns non-mesh --context $CTX_EAST 2>/dev/null || true
kubectl run curl-nomesh -n non-mesh --context $CTX_EAST \
  --image=curlimages/curl:7.83.1 --restart=Never --command -- sleep infinity 2>/dev/null || true
```

Wait for the pod to be ready:

```bash
kubectl wait --for=condition=Ready pod/curl-nomesh -n non-mesh --context $CTX_EAST --timeout=30s
```

### Test 1a: Non-mesh → nginx (local svc.cluster.local)

```bash
kubectl -n non-mesh exec curl-nomesh --context $CTX_EAST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.svc:8080
```

**Expected:** Connection refused, reset, or timeout — STRICT mTLS rejects plaintext from a non-mesh client.

### Test 1b: Non-mesh → nginx (cross-cluster mesh.internal)

```bash
kubectl -n non-mesh exec curl-nomesh --context $CTX_EAST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.mesh.internal:8080
```

**Expected:** Failure — `mesh.internal` hostname is only resolvable and routable from within the ambient mesh.

---

## Test 2: Client INSIDE the mesh (ambient-enrolled namespace)

The `default` namespace is enrolled in ambient. curl-client has identity `spiffe://demo-east.local/ns/default/sa/curl-client`.

### Test 2a: Mesh client → nginx (local svc.cluster.local)

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- \
  curl -s -w "\nHTTP %{http_code}\n" nginx-service.nginx.svc:8080
```

**Expected:** HTTP 200 + response body. Traffic is mTLS-encrypted by ztunnel.

### Test 2b: Mesh client → nginx (cross-cluster mesh.internal)

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 6); do
  kubectl -n default exec $CURL_POD --context $CTX_EAST -- \
    curl -s -w " | HTTP %{http_code}\n" nginx-service.nginx.mesh.internal:8080
done
```

**Expected:** HTTP 200 from both EAST and WEST clusters, all via mTLS.

### Test 2c: Verify mTLS in ztunnel logs

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_EAST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=30s 2>&1 | grep -E "src.identity.*spiffe" | head -5
```

**Expected:** Every connection shows SPIFFE identities proving mTLS:
```
src.identity="spiffe://demo-east.local/ns/default/sa/curl-client"
dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
```

---

## Test 3: Cross-cluster client OUTSIDE the mesh

Deploy a non-mesh curl pod on the west cluster:

```bash
kubectl create ns non-mesh --context $CTX_WEST 2>/dev/null || true
kubectl run curl-nomesh -n non-mesh --context $CTX_WEST \
  --image=curlimages/curl:7.83.1 --restart=Never --command -- sleep infinity 2>/dev/null || true
kubectl wait --for=condition=Ready pod/curl-nomesh -n non-mesh --context $CTX_WEST --timeout=30s
```

### Test 3a: Non-mesh west → nginx west (local)

```bash
kubectl -n non-mesh exec curl-nomesh --context $CTX_WEST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.svc:8080
```

**Expected:** Connection refused or timeout — STRICT mTLS blocks plaintext even on the local cluster.

### Test 3b: Non-mesh west → nginx east (mesh.internal)

```bash
kubectl -n non-mesh exec curl-nomesh --context $CTX_WEST -- \
  curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.mesh.internal:8080
```

**Expected:** Failure — non-mesh pods cannot resolve or route to `mesh.internal`.

### Test 3c: Mesh west → nginx east (cross-cluster mTLS proof)

```bash
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_WEST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 6); do
  kubectl -n default exec $CURL_POD --context $CTX_WEST -- \
    curl -s -w " | HTTP %{http_code}\n" nginx-service.nginx.mesh.internal:8080
done
```

**Expected:** HTTP 200 from both clusters. Cross-trust-domain mTLS between `demo-east.local` and `demo-west.local`.

### Test 3d: Verify cross-cluster mTLS identities

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_WEST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_WEST --since=30s 2>&1 | grep -E "spiffe.*demo" | head -5
```

**Expected:** Both trust domains visible in the same connection:
```
src.identity="spiffe://demo-west.local/ns/default/sa/curl-client"
dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
```

---

## Results Summary

| Test | Source | Destination | Mesh? | Expected |
|---|---|---|---|---|
| 1a | non-mesh (east) | nginx local | No | Blocked (STRICT mTLS) |
| 1b | non-mesh (east) | nginx mesh.internal | No | Blocked (no mesh routing) |
| 2a | curl-client (east) | nginx local | Yes | HTTP 200 (mTLS) |
| 2b | curl-client (east) | nginx mesh.internal | Yes | HTTP 200 (mTLS, cross-cluster) |
| 3a | non-mesh (west) | nginx local | No | Blocked (STRICT mTLS) |
| 3b | non-mesh (west) | nginx mesh.internal | No | Blocked (no mesh routing) |
| 3c | curl-client (west) | nginx mesh.internal | Yes | HTTP 200 (cross-trust-domain mTLS) |

## Cleanup (optional)

```bash
kubectl delete peerauthentication strict-mtls -n nginx --context $CTX_EAST
kubectl delete peerauthentication strict-mtls -n nginx --context $CTX_WEST
kubectl delete pod curl-nomesh -n non-mesh --context $CTX_EAST
kubectl delete pod curl-nomesh -n non-mesh --context $CTX_WEST
kubectl delete ns non-mesh --context $CTX_EAST
kubectl delete ns non-mesh --context $CTX_WEST
```

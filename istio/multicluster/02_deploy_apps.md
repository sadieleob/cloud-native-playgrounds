# Multicluster Ambient Mesh - Deploy Applications

## Step 1: Deploy nginx in both clusters

The same service name (`nginx-service`) is deployed in both clusters with different response bodies to identify which cluster handled the request.

### demo-east

```bash
kubectl apply -f manifests/nginx-east.yaml --context $CTX_EAST
```

### demo-west

```bash
kubectl apply -f manifests/nginx-west.yaml --context $CTX_WEST
```

### Verify

```bash
kubectl get pods -n nginx --context $CTX_EAST
kubectl get pods -n nginx --context $CTX_WEST
```

## Step 2: Deploy curl client

```bash
kubectl apply -f manifests/curl-client.yaml --context $CTX_EAST
kubectl apply -f manifests/curl-client.yaml --context $CTX_WEST
```

## Step 3: Enable cross-cluster service federation

Label the nginx services with `solo.io/service-scope=global` to make them discoverable across clusters. This creates a global hostname `nginx-service.nginx.mesh.internal`.

```bash
kubectl label svc nginx-service -n nginx --context $CTX_EAST solo.io/service-scope=global
kubectl label svc nginx-service -n nginx --context $CTX_WEST solo.io/service-scope=global
```

**Important:** `solo.io/service-scope=global` must be a **label**, not an annotation.

### Verify ServiceEntry creation

```bash
kubectl get serviceentry -A --context $CTX_EAST
kubectl get serviceentry -A --context $CTX_WEST
```

Expected output:
```
NAMESPACE      NAME                          HOSTS                                   LOCATION        RESOLUTION   AGE
istio-system   autogen.nginx.nginx-service   ["nginx-service.nginx.mesh.internal"]   MESH_INTERNAL   STATIC       10s
```

### Verify endpoints

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep nginx
```

Expected: `autogen.nginx.nginx-service` should show **2/2** endpoints (local + remote).

## Step 4: Test local traffic

```bash
# From east
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s nginx-service.nginx.svc:8080
# Expected: "You hit EAST cluster (demo-east)"

# From west
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_WEST -o jsonpath='{.items[0].metadata.name}')
kubectl -n default exec $CURL_POD --context $CTX_WEST -- curl -s nginx-service.nginx.svc:8080
# Expected: "You hit WEST cluster (demo-west)"
```

Local `svc.cluster.local` hostnames always route to local endpoints only.

## Step 5: Test cross-cluster traffic

Use the `mesh.internal` hostname for cross-cluster routing:

```bash
# From east — should hit BOTH east and west
CURL_POD=$(kubectl get pod -l app=curl-client -n default --context $CTX_EAST -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 10); do
  kubectl -n default exec $CURL_POD --context $CTX_EAST -- curl -s nginx-service.nginx.mesh.internal:8080
done
```

Expected: Mix of "You hit EAST cluster" and "You hit WEST cluster" responses, demonstrating cross-cluster load balancing via the east-west gateways.

## Step 6: Verify mTLS

Check ztunnel logs for SPIFFE identity-based mTLS:

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_EAST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=30s | grep spiffe | head -5
```

Expected: SPIFFE identities like:
```
src.identity="spiffe://demo-east.local/ns/default/sa/curl-client"
dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
```

For cross-cluster traffic, you'll see the remote trust domain:
```
src.identity="spiffe://demo-west.local/ns/nginx/sa/waypoint"
```

## Hostnames Summary

| Hostname | Scope | Use |
|---|---|---|
| `nginx-service.nginx.svc:8080` | Local cluster only | Standard K8s service resolution |
| `nginx-service.nginx.mesh.internal:8080` | Cross-cluster | Global service with all endpoints |

Next: [03_demo_policies.md](03_demo_policies.md)

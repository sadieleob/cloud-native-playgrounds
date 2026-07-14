# Deploy Applications

## Step 1: Deploy nginx

### demo-east

```bash
kubectl apply -f manifests/nginx-east.yaml --context $CTX_EAST
```

### demo-west

```bash
kubectl apply -f manifests/nginx-west.yaml --context $CTX_WEST
```

Both manifests create:
- `nginx` namespace with `istio.io/dataplane-mode: ambient`
- ConfigMap with cluster-identifying HTML response
- Deployment with 1 replica
- Service on port 8080 → targetPort 80, with labels:
  - `solo.io/service-scope: global` — makes the service discoverable across clusters
  - `istio.io/ingress-use-waypoint: "true"` — routes kgateway ingress traffic through waypoint proxies (kgateway skips waypoints by default)

## Step 2: Deploy curl client

```bash
kubectl apply -f manifests/curl-client.yaml --context $CTX_EAST
kubectl apply -f manifests/curl-client.yaml --context $CTX_WEST
```

## Step 3: Verify cross-cluster service federation

The `solo.io/service-scope=global` label triggers auto-generation of a ServiceEntry with the `mesh.internal` hostname.

```bash
kubectl get serviceentry -A --context $CTX_EAST
kubectl get serviceentry -A --context $CTX_WEST
```

Expected:
```
NAMESPACE      NAME                          HOSTS                                   LOCATION        RESOLUTION   AGE
istio-system   autogen.nginx.nginx-service   ["nginx-service.nginx.mesh.internal"]   MESH_INTERNAL   STATIC       10s
```

Verify endpoints from both clusters are visible:

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep nginx
```

Expected: `autogen.nginx.nginx-service` with **2/2** endpoints (local + remote).

## Step 4: Test local traffic

```bash
kubectl -n default exec deploy/curl-client --context $CTX_EAST -- curl -s nginx-service.nginx.svc:8080
# Expected: "You hit EAST cluster (demo-east)"

kubectl -n default exec deploy/curl-client --context $CTX_WEST -- curl -s nginx-service.nginx.svc:8080
# Expected: "You hit WEST cluster (demo-west)"
```

Local `svc.cluster.local` hostnames always route to local endpoints only.

## Step 5: Test cross-cluster traffic

Use the `mesh.internal` hostname for cross-cluster routing:

```bash
for i in $(seq 1 10); do kubectl -n default exec deploy/curl-client --context $CTX_EAST -- curl -s nginx-service.nginx.mesh.internal:8080; done
```

Expected: Mix of "EAST" and "WEST" responses.

## Step 6: Verify mTLS

```bash
ZTUNNEL=$(kubectl get pods -n istio-system --context $CTX_EAST -l app=ztunnel -o jsonpath='{.items[0].metadata.name}')
kubectl logs $ZTUNNEL -n istio-system --context $CTX_EAST --since=30s | grep spiffe | head -5
```

Expected SPIFFE identities:
```
src.identity="spiffe://demo-east.local/ns/default/sa/curl-client"
dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
```

## Hostnames

| Hostname | Scope | Use |
|---|---|---|
| `nginx-service.nginx.svc:8080` | Local cluster only | Standard K8s service resolution |
| `nginx-service.nginx.mesh.internal:8080` | Cross-cluster | Global service with all endpoints |

Next: [04_demo_policies.md](04_demo_policies.md)

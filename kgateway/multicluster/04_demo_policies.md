# Waypoint & Authorization Policies

## Step 1: Deploy waypoint proxies

```bash
kubectl apply -f manifests/waypoint.yaml --context $CTX_EAST
kubectl apply -f manifests/waypoint.yaml --context $CTX_WEST
```

Verify:

```bash
kubectl get gateway waypoint -n nginx --context $CTX_EAST
kubectl get gateway waypoint -n nginx --context $CTX_WEST
```

Expected: `PROGRAMMED: True` on both.

## Step 2: Attach waypoints to nginx service

```bash
kubectl label svc nginx-service -n nginx istio.io/use-waypoint=waypoint --context $CTX_EAST
kubectl label svc nginx-service -n nginx istio.io/use-waypoint=waypoint --context $CTX_WEST
```

## Step 3: Apply AuthorizationPolicies

```bash
kubectl apply -f manifests/authz-policies.yaml --context $CTX_EAST
kubectl apply -f manifests/authz-policies.yaml --context $CTX_WEST
```

Three policies, all targeting the waypoint Gateway:

| Policy | Action | Effect |
|---|---|---|
| `nginx-default-deny` | (empty = deny all) | Block all traffic to nginx by default |
| `nginx-allow-default-ns` | ALLOW | `default` and `kgateway-system` namespaces can reach nginx |
| `deny-west-restricted` | DENY | Block traffic from `demo-west.local/ns/restricted/sa/default` |

**Why target the Gateway, not the Service?** Service-targeted policies only match traffic to the local `svc.cluster.local` VIP. Cross-cluster traffic arrives on the auto-generated `mesh.internal` ServiceEntry, which is a different VIP. Targeting the waypoint Gateway catches ALL traffic — local and cross-cluster.

## Step 4: Create restricted namespace for testing

```bash
for CTX in $CTX_EAST $CTX_WEST; do
  kubectl create ns restricted --context $CTX
  kubectl label ns restricted istio.io/dataplane-mode=ambient --context $CTX
  kubectl run curl-restricted -n restricted --context $CTX \
    --image=curlimages/curl:7.83.1 --restart=Never --command -- sleep infinity
done
```

## Step 5: Test AuthZ enforcement

### Allowed: default ns -> nginx (local)

```bash
kubectl -n default exec deploy/curl-client --context $CTX_EAST -- curl -s -o /dev/null -w "HTTP %{http_code}" nginx-service.nginx.svc:8080
# Expected: HTTP 200
```

### Denied: restricted ns -> nginx (local)

```bash
kubectl -n restricted exec curl-restricted --context $CTX_EAST -- curl -s -o /dev/null -w "HTTP %{http_code}" --max-time 5 nginx-service.nginx.svc:8080
# Expected: HTTP 403
```

### Allowed: default ns -> mesh.internal (cross-cluster)

```bash
for i in $(seq 1 6); do kubectl -n default exec deploy/curl-client --context $CTX_EAST -- curl -s nginx-service.nginx.mesh.internal:8080; done
# Expected: HTTP 200, mix of EAST and WEST
```

### Denied: restricted ns -> mesh.internal (cross-cluster)

```bash
for i in $(seq 1 6); do kubectl -n restricted exec curl-restricted --context $CTX_WEST -- curl -s -w " | HTTP %{http_code}\n" --max-time 5 nginx-service.nginx.mesh.internal:8080; done
# Expected: HTTP 403 from both clusters
```

## What this proves

| Capability | Evidence |
|---|---|
| Automatic mTLS | ztunnel logs show SPIFFE identities on every connection |
| Cross-cluster service discovery | `mesh.internal` hostname resolves endpoints in both clusters |
| Cross-cluster load balancing | Requests distribute across east and west nginx |
| L7 AuthorizationPolicy | Waypoint enforces namespace-based allow/deny |
| Cross-cluster identity enforcement | Trust domain principals (`demo-west.local/ns/...`) used in deny rules |
| Zero-trust default deny | Only explicitly allowed traffic reaches the service |

Next: [05_kgateway_ingress.md](05_kgateway_ingress.md)

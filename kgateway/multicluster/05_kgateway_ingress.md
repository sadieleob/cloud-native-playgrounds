# KGateway N-S Ingress + Cross-Cluster Routing

## HTTPRoute with mesh.internal Hostname

The `kind: Hostname` with `group: networking.istio.io` backendRef tells kgateway to route to the auto-generated ServiceEntry for the global `mesh.internal` hostname. This gives us cross-cluster load balancing on the north-south path.

```bash
kubectl apply --context $CTX_EAST -f manifests/httproute-nginx.yaml
```

Or inline:

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-ingress
  namespace: kgateway-system
spec:
  parentRefs:
  - name: http
    namespace: kgateway-system
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

**Notes:**
- The `port` must match the Service `port` (8080), not the container `targetPort` (80)
- Hostname format: `<service>.<namespace>.mesh.internal` (changes if segments are configured)
- Requires `KGW_ENABLE_ISTIO_INTEGRATION=true` on the kgateway controller (set in Step 2 of the install)
- If the service has `solo.io/service-takeover` label, that does NOT affect ingress routing — it only redirects in-mesh E-W traffic. The `backendRefs` must still reference the `mesh.internal` hostname explicitly.
- **Known issue:** In Solo Istio versions before 1.29.2-patch0 and 1.28.6, named `targetPort` values (e.g. `targetPort: http`) are not correctly resolved. Workaround: use numeric `targetPort` in the Service definition. Our manifests already use numeric `targetPort: 80`.

## Test: N-S ingress with cross-cluster load balancing

```bash
for i in $(seq 1 10); do curl -s -H "Host: nginx.demo.example.com" http://${INGRESS_GW_ADDRESS}:8080; done
```

Expected: Mix of "EAST" and "WEST" responses.

```bash
for i in $(seq 1 10); do curl -s -H "Host: nginx.demo.example.com" http://${INGRESS_GW_ADDRESS}:8080; done | sort | uniq -c
```

## mTLS verification

The kgateway proxy is enrolled in the ambient mesh (`kgateway-system` namespace labeled ambient). ztunnel intercepts its outbound connections and wraps them in mTLS.

### Verify kgateway proxy SPIFFE identity

```bash
kubectl logs -n istio-system --context $CTX_EAST -l app=ztunnel --since=30s | grep "kgateway-system" | head -3
```

Expected: `src.identity="spiffe://demo-east.local/ns/kgateway-system/sa/http"`

### Traffic path

```
External Client
      | (plaintext HTTP)
      v
+---------------------+
| KGateway Proxy      |  spiffe://demo-east.local/ns/kgateway-system/sa/http
| (kgateway-system)   |
+---------+-----------+
          | mTLS (ztunnel -> HBONE)
          v
+---------------------+
| Waypoint Proxy      |  spiffe://demo-east.local/ns/nginx/sa/waypoint
| (nginx namespace)   |  <- AuthZ policies enforced here
+---------+-----------+
          | mTLS (ztunnel -> HBONE)
     +----+----+
     v         v
+---------+ +---------+
| nginx   | | nginx   |
| (EAST)  | | (WEST)  |  <- via east-west gateway (HBONE tunnel)
+---------+ +---------+
```

Two mTLS hops:
1. **KGateway -> Waypoint:** `src=http (kgateway SA)`, `dst=waypoint`
2. **Waypoint -> nginx:** `src=waypoint`, `dst=nginx-service`

The `istio.io/ingress-use-waypoint: "true"` label on the nginx service is what makes kgateway route through the waypoint instead of directly to the pod.

### AuthZ on N-S traffic

The `manifests/authz-policies.yaml` already includes `kgateway-system` in the ALLOW rule alongside `default`. This is necessary because kgateway's proxy runs in `kgateway-system` — without it, the waypoint's default-deny would block N-S ingress traffic.

Next: [06_failover.md](06_failover.md)

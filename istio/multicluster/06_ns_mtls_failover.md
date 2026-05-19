# North-South mTLS + Cross-Cluster Failover Demo

Demonstrates end-to-end mTLS from the Gloo Gateway ingress proxy through the ambient mesh to nginx, and automatic failover to the west cluster when the east nginx is scaled down.

## Prerequisites

```bash
export CTX_EAST=kind-demo-east
export CTX_WEST=kind-demo-west
export INGRESS_GW_ADDRESS=$(kubectl get svc -n gloo-system gloo-proxy-http --context $CTX_EAST -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo "Gateway: $INGRESS_GW_ADDRESS"
```

---

## Part 1: mTLS from NS Gateway to Global Workload

### Verify: Gloo Gateway proxy has a SPIFFE identity

```bash
kubectl logs -n istio-system --context $CTX_EAST -l app=ztunnel --since=30s | grep "gloo-proxy" | head -3
```

**Expected:** `src.identity="spiffe://demo-east.local/ns/gloo-system/sa/gloo-proxy-http"`

### Send traffic through the NS gateway

```bash
for i in $(seq 1 10); do
  curl -s http://${INGRESS_GW_ADDRESS}:8080/ -H "host: nginx.demo.example.com"
done
```

**Expected:** Mix of EAST and WEST responses — traffic enters Gloo Gateway and is load-balanced across both clusters via `nginx-service.nginx.mesh.internal`.

### Verify: Full mTLS chain in ztunnel logs

```bash
kubectl logs -n istio-system --context $CTX_EAST -l app=ztunnel --since=15s 2>&1 | grep "nginx" | head -5
```

**Expected:** Two hops, both mTLS:

1. **Gloo Gateway → Waypoint** (L7 policy enforcement):
   ```
   src.identity="spiffe://demo-east.local/ns/gloo-system/sa/gloo-proxy-http"
   dst.identity="spiffe://demo-east.local/ns/nginx/sa/waypoint"
   ```

2. **Waypoint → nginx** (final delivery):
   ```
   src.identity="spiffe://demo-east.local/ns/nginx/sa/waypoint"
   dst.identity="spiffe://demo-east.local/ns/nginx/sa/nginx-service"
   ```

### Verify: Cross-cluster mTLS (traffic hitting west)

```bash
kubectl logs -n istio-system --context $CTX_WEST -l app=ztunnel --since=15s 2>&1 | grep "nginx-service" | head -3
```

**Expected:** West ztunnel shows inbound from east's waypoint or east-west gateway with a `demo-east.local` trust domain identity.

### Traffic path diagram

```
External Client
      │ (plaintext HTTP)
      ▼
┌─────────────────────┐
│ Gloo Gateway Proxy  │  spiffe://demo-east.local/ns/gloo-system/sa/gloo-proxy-http
│ (gloo-system)       │
└─────────┬───────────┘
          │ mTLS (ztunnel → HBONE)
          ▼
┌─────────────────────┐
│ Waypoint Proxy      │  spiffe://demo-east.local/ns/nginx/sa/waypoint
│ (nginx namespace)   │  ← AuthZ policies enforced here
└─────────┬───────────┘
          │ mTLS (ztunnel → HBONE)
     ┌────┴────┐
     ▼         ▼
┌─────────┐ ┌─────────┐
│ nginx   │ │ nginx   │
│ (EAST)  │ │ (WEST)  │  ← via east-west gateway (HBONE tunnel)
└─────────┘ └─────────┘
```

---

## Part 2: Failover — Scale Down East, West Takes Over

### Baseline: Confirm both clusters are serving

```bash
for i in $(seq 1 10); do
  curl -s http://${INGRESS_GW_ADDRESS}:8080/ -H "host: nginx.demo.example.com"
done | sort | uniq -c
```

**Expected:** Roughly even split between EAST and WEST.

### Check endpoint count before failover

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
```

**Expected:** `2/2` endpoints (one local, one remote).

### Scale down east nginx to 0

```bash
kubectl scale deployment nginx-service -n nginx --replicas=0 --context $CTX_EAST
```

### Wait for endpoint removal

```bash
kubectl get pods -n nginx --context $CTX_EAST -l app=nginx-service
```

**Expected:** No pods running.

### Verify endpoint count after failover

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
```

**Expected:** `1/1` endpoint (only the remote west endpoint remains).

### Test: All traffic now goes to WEST

```bash
for i in $(seq 1 10); do
  curl -s http://${INGRESS_GW_ADDRESS}:8080/ -H "host: nginx.demo.example.com"
done
```

**Expected:** ALL responses say "You hit WEST cluster (demo-west)" — automatic failover with zero downtime.

### Verify: mTLS still active during failover

```bash
kubectl logs -n istio-system --context $CTX_EAST -l app=ztunnel --since=15s 2>&1 | grep "nginx" | head -3
```

**Expected:** Traffic still shows SPIFFE identities — mTLS is maintained even when all traffic routes cross-cluster through the east-west gateway.

---

## Part 3: Recovery — Scale East Back Up

### Scale east nginx back to 1

```bash
kubectl scale deployment nginx-service -n nginx --replicas=1 --context $CTX_EAST
```

### Wait for pod ready

```bash
kubectl wait --for=condition=Ready pod -l app=nginx-service -n nginx --context $CTX_EAST --timeout=30s
```

### Verify endpoint count restored

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
```

**Expected:** `2/2` endpoints (both clusters serving again).

### Test: Load balancing restored

```bash
for i in $(seq 1 10); do
  curl -s http://${INGRESS_GW_ADDRESS}:8080/ -H "host: nginx.demo.example.com"
done | sort | uniq -c
```

**Expected:** Mix of EAST and WEST responses — automatic recovery.

---

## Summary

| Phase | East nginx | West nginx | Result |
|---|---|---|---|
| Baseline | 1 replica | 1 replica | Load balanced across both clusters |
| Failover | 0 replicas | 1 replica | 100% traffic to west, zero downtime |
| Recovery | 1 replica | 1 replica | Load balanced again |

All phases maintain end-to-end mTLS from the Gloo Gateway proxy through the ambient mesh (ztunnel + waypoint) to the nginx backend, with SPIFFE identities at every hop.

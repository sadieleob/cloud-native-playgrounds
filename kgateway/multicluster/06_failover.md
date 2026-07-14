# Cross-Cluster Failover

## Baseline

Confirm load balancing across both clusters:

```bash
for i in $(seq 1 10); do curl -s -H "Host: nginx.demo.example.com" http://${INGRESS_GW_ADDRESS}:8080; done | sort | uniq -c
```

Expected: Roughly even split between EAST and WEST.

Check endpoint count:

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
# Expected: 2/2 endpoints
```

## Failover: Scale East to Zero

```bash
kubectl scale deployment nginx-service -n nginx --replicas=0 --context $CTX_EAST
```

Verify endpoint count dropped:

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
# Expected: 1/1 endpoint (only remote west)
```

Test — all traffic should go to WEST:

```bash
for i in $(seq 1 10); do curl -s -H "Host: nginx.demo.example.com" http://${INGRESS_GW_ADDRESS}:8080; done
# Expected: ALL responses say "You hit WEST cluster (demo-west)"
```

mTLS is maintained even when all traffic routes cross-cluster through the east-west gateway.

## Recovery: Scale East Back Up

```bash
kubectl scale deployment nginx-service -n nginx --replicas=1 --context $CTX_EAST
kubectl wait --for=condition=Ready pod -l app=nginx-service -n nginx --context $CTX_EAST --timeout=30s
```

Verify endpoints restored:

```bash
istioctl ztunnel-config service --context $CTX_EAST | grep autogen.nginx.nginx-service
# Expected: 2/2 endpoints
```

Test — load balancing should be back:

```bash
for i in $(seq 1 10); do curl -s -H "Host: nginx.demo.example.com" http://${INGRESS_GW_ADDRESS}:8080; done | sort | uniq -c
# Expected: Mix of EAST and WEST
```

## Results

| Phase | East nginx | West nginx | Result |
|---|---|---|---|
| Baseline | 1 replica | 1 replica | Load balanced across both clusters |
| Failover | 0 replicas | 1 replica | 100% traffic to west, zero downtime |
| Recovery | 1 replica | 1 replica | Load balanced again |

## N-S vs E-W Failover Behavior

This is a behavioral difference worth calling out:

- **East-west (pod-to-pod via ztunnel):** ztunnel detects `NotReady` pods and excludes them from endpoint selection. Failover triggers on unhealthy pods.
- **North-south (kgateway ingress):** kgateway resolves the `mesh.internal` hostname to a ServiceEntry VIP. Cross-cluster failover only triggers when **all local pods are scaled to zero** (no local endpoints exist). Pods in `NotReady` state do NOT trigger N-S failover — they still receive traffic until fully removed.

This is documented behavior in the kgateway 2.2.x ambient multicluster docs.

Next: [07_architecture.md](07_architecture.md)

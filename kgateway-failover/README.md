# Kgateway Priority Groups Failover

Multi-tier active/passive failover using `priorityGroups` on the `Backend` CRD.
Available in kgateway enterprise 2.3.0+.

Each static backend has its own DNS/hostname. Envoy health checks drive failover
and recovery in the data plane — no control plane involvement during transitions.

Ref: [kgateway PR #14379](https://github.com/kgateway-dev/kgateway/pull/14379)

## Architecture

```
              ┌──────────────────┐
              │ failover-priority│  (Backend: priorityGroups)
              └────────┬─────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   Priority 0     Priority 1     Priority 2
  ┌───────────┐  ┌───────────┐  ┌───────────┐
  │  backend- │  │  backend- │  │  backend- │
  │   omaha   │  │   east1   │  │   west2   │
  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘
        │               │              │
   nginx-omaha     nginx-east1    nginx-west2
  (datacenter)    (aws us-east)  (aws us-west)
```

Traffic goes to the highest-priority healthy group. When health degrades below ~71%
(Envoy overprovisioning factor 140%), traffic spills to the next group. Recovery is
automatic.

## Setup

### Kind cluster

```bash
cat <<EOF | kind create cluster --name failover-demo --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF
```

### Install kgateway enterprise 2.3.0-rc.2

```bash
# Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# Kgateway CRDs
helm upgrade -i enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --version 2.3.0-rc.2 \
  -n kgateway-system --create-namespace

# Kgateway controller
helm upgrade -i enterprise-kgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
  --version 2.3.0-rc.2 \
  -n kgateway-system \
  --set licensing.licenseKey=$GLOO_GATEWAY_LICENSE_KEY
```

### Deploy the demo

```bash
kubectl apply -f priority-groups-demo.yaml
```

Wait for pods:
```bash
kubectl -n failover-pg get pods
kubectl -n failover-pg get backends
```

## Test

### Live failover script

```bash
chmod +x test-failover.sh
./test-failover.sh
```

In a second terminal, scale backends to trigger failover:

```bash
# Kill primary → failover to priority 1
kubectl -n failover-pg scale deployment nginx-omaha --replicas=0

# Kill east1 → cascade to priority 2
kubectl -n failover-pg scale deployment nginx-east1 --replicas=0

# Restore primary → auto-recovery to priority 0
kubectl -n failover-pg scale deployment nginx-omaha --replicas=1

# Restore east1 → traffic stays on priority 0
kubectl -n failover-pg scale deployment nginx-east1 --replicas=1
```

Example output:
```
TIME         REGION               PRIORITY   STATUS
------------------------------------------------------------
09:55:01     datacenter-omaha     0          primary
09:55:02     datacenter-omaha     0          primary
09:55:03     aws-us-east-1        1          failover-1     ← omaha scaled to 0
09:55:04     aws-us-east-1        1          failover-1
09:55:05     aws-us-west-2        2          failover-2     ← east1 scaled to 0
09:55:06     aws-us-west-2        2          failover-2
09:55:08     datacenter-omaha     0          primary        ← omaha restored
```

### Manual tests

```bash
GW_IP=$(kubectl -n kgateway-system get gateway failover-pg-gw -o jsonpath='{.status.addresses[0].value}')

# All traffic to priority 0
for i in $(seq 1 5); do curl -s -H "host: failover-pg.example.com" http://$GW_IP:8090/; done

# Kill primary, wait ~5s, verify failover to priority 1
kubectl -n failover-pg scale deployment nginx-omaha --replicas=0
sleep 5
for i in $(seq 1 5); do curl -s -H "host: failover-pg.example.com" http://$GW_IP:8090/; done

# Kill east1 too, verify cascade to priority 2
kubectl -n failover-pg scale deployment nginx-east1 --replicas=0
sleep 5
for i in $(seq 1 5); do curl -s -H "host: failover-pg.example.com" http://$GW_IP:8090/; done

# Restore primary, verify recovery
kubectl -n failover-pg scale deployment nginx-omaha --replicas=1
sleep 5
for i in $(seq 1 5); do curl -s -H "host: failover-pg.example.com" http://$GW_IP:8090/; done
```

### Verify Envoy config

```bash
PROXY_POD=$(kubectl -n kgateway-system get pod -l gateway.networking.k8s.io/gateway-name=failover-pg-gw -o jsonpath='{.items[0].metadata.name}')
kubectl -n kgateway-system exec $PROXY_POD -- wget -q -O- http://localhost:19000/config_dump 2>/dev/null | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    if 'dynamic_active_clusters' in config:
        for cluster in config['dynamic_active_clusters']:
            c = cluster.get('cluster', {})
            if 'failover-priority' in c.get('name', ''):
                print(f'Cluster: {c[\"name\"]}')
                for ep in c.get('load_assignment', {}).get('endpoints', []):
                    p = ep.get('priority', 0)
                    for lbe in ep.get('lb_endpoints', []):
                        sa = lbe['endpoint']['address']['socket_address']
                        print(f'  Priority {p}: {sa[\"address\"]}:{sa[\"port_value\"]}')
                for hc in c.get('health_checks', []):
                    print(f'  Health check: interval={hc[\"interval\"]}, timeout={hc[\"timeout\"]}, path={hc.get(\"http_health_check\",{}).get(\"path\")}')
"
```

Expected:
```
Cluster: backend_failover-pg_failover-priority_0
  Priority 0: nginx-omaha.failover-pg.svc.cluster.local:80
  Priority 1: nginx-east1.failover-pg.svc.cluster.local:80
  Priority 2: nginx-west2.failover-pg.svc.cluster.local:80
  Health check: interval=2s, timeout=1s, path=/
```

## Limitations

- Static backends only (no Lambda, GCP, DynamicForwardProxy)
- Group members must be in the same namespace
- No per-group weights (endpoints within a group are load balanced equally)
- Up to 16 priority levels, up to 16 backends per group
- Marked as experimental in 2.3.0

## Cleanup

```bash
kubectl delete -f priority-groups-demo.yaml
kind delete cluster --name failover-demo
```

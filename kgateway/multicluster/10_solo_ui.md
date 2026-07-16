# Solo UI Deployment (Multicluster Ambient Mesh + kgateway)

Deploy the Solo UI observability stack across a multicluster Istio ambient mesh with Enterprise kgateway. Provides service graph, live metrics, mTLS visualization, and cross-cluster dashboard.

**Version:** Solo UI 0.4.6
**Reference:** https://docs.solo.io/istio/1.30.x/setup/setup/

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Cluster 1 (Management)                       │
│                                                                      │
│  istiod ─────────┐                                                   │
│  ztunnel ────────┤  Prometheus /metrics                              │
│  waypoint ───────┤                                                   │
│  gateways ───────┘                                                   │
│        │                                                             │
│        ▼                                                             │
│  ┌────────────────────────────────────┐                              │
│  │ OTel Collector (solo-enterprise)   │                              │
│  │ Scrapes Prometheus endpoints       │                              │
│  │ Transforms → ClickHouse inserts    │                              │
│  └──────────────┬─────────────────────┘                              │
│                 │                                                     │
│                 ▼                                                     │
│  ┌────────────────────────────────────┐     ┌──────────────────────┐ │
│  │ ClickHouse (shard0)               │ ◄── │ Solo UI Backend      │ │
│  │ Stores: metrics, traces, k8s obj  │     │ Service graph, etc.  │ │
│  └────────────────────────────────────┘     └──────────────────────┘ │
│                                                                      │
│        ▲ Telemetry Gateway (LB)                                      │
│        │                                                             │
└────────┼─────────────────────────────────────────────────────────────┘
         │
         │ OTel (gRPC, port 4316)
         │
┌────────┼─────────────────────────────────────────────────────────────┐
│        │                    Cluster 2 (Relay)                         │
│  ┌─────┴──────────────────────────────┐                              │
│  │ OTel Collector (solo-enterprise)   │                              │
│  │ Scrapes local Prometheus endpoints │                              │
│  │ Exports to mgmt telemetry gateway  │                              │
│  └────────────────────────────────────┘                              │
│                                                                      │
│  ┌────────────────────────────────────┐                              │
│  │ Relay (solo-enterprise)            │                              │
│  │ Tunnel client → mgmt UI (9000)     │                              │
│  │ Ships K8s resources to mgmt        │                              │
│  └────────────────────────────────────┘                              │
└──────────────────────────────────────────────────────────────────────┘

IMPORTANT: solo-enterprise namespace must NOT be enrolled in ambient mesh.
ztunnel intercepts ClickHouse (port 9000) and OTel collector (port 4316),
breaking raw TCP protocols.
```

---

## Prerequisites

- Multicluster Istio ambient mesh installed ([01_install_ambient.md](01_install_ambient.md))
- Enterprise kgateway installed ([02_install_kgateway.md](02_install_kgateway.md))
- Apps deployed to the mesh ([03_deploy_apps.md](03_deploy_apps.md))
- Solo Enterprise for Istio license key
- `DEBUG_ENDPOINT_AUTH_ALLOWED_NAMESPACES` set in istiod (required for Istio 1.29.0+)

### Update istiod to Allow Solo UI Access

On both clusters, add `solo-enterprise` to the debug endpoint allowed namespaces:

```bash
helm upgrade istiod oci://us-docker.pkg.dev/soloio-img/istio-helm/istiod \
  --kube-context ${CONTEXT1} \
  -n istio-system \
  --version ${ISTIO_VERSION} \
  --reuse-values \
  --set env.DEBUG_ENDPOINT_AUTH_ALLOWED_NAMESPACES="gloo-mesh\,solo-enterprise"
```

Repeat for `${CONTEXT2}`.

---

## Step 1: Install Management Chart

On the management cluster:

```bash
export SOLO_UI_VERSION=0.4.6

helm upgrade -i solo-management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  -n solo-enterprise --create-namespace \
  --kube-context ${CONTEXT1} \
  --version ${SOLO_UI_VERSION} \
  --set cluster=${CLUSTER1} \
  --set licensing.licenseKey=${SOLO_ISTIO_LICENSE_KEY} \
  --set oidc.issuer="" \
  --set products.mesh.enabled=true
```

Verify pods:
```bash
kubectl --context ${CONTEXT1} -n solo-enterprise get pods
```

Expected:
```
NAME                                    READY   STATUS    RESTARTS   AGE
solo-enterprise-telemetry-collector-0   1/1     Running   0          30s
solo-enterprise-ui-xxxxxxxxxx-xxxxx     5/5     Running   0          30s
solo-management-clickhouse-shard0-0     1/1     Running   0          30s
```

## Step 2: Register Clusters

Create `KubernetesCluster` CRs so the UI backend discovers each cluster:

```bash
kubectl --context ${CONTEXT1} apply -f - <<EOF
apiVersion: platform.solo.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: ${CLUSTER1}
  namespace: solo-enterprise
spec: {}
---
apiVersion: platform.solo.io/v1alpha1
kind: KubernetesCluster
metadata:
  name: ${CLUSTER2}
  namespace: solo-enterprise
spec: {}
EOF
```

## Step 3: Install Relay Chart

Get the management cluster's service endpoints:

```bash
# Telemetry gateway IP
kubectl --context ${CONTEXT1} -n solo-enterprise get svc solo-enterprise-telemetry-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Tunnel server IP (same as UI service)
kubectl --context ${CONTEXT1} -n solo-enterprise get svc solo-enterprise-ui \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Install the relay on the remote cluster:

```bash
helm upgrade -i solo-relay \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/relay \
  -n solo-enterprise --create-namespace \
  --kube-context ${CONTEXT2} \
  --version ${SOLO_UI_VERSION} \
  --set cluster=${CLUSTER2} \
  --set tunnel.fqdn=${TUNNEL_IP} \
  --set tunnel.port=9000 \
  --set telemetry.fqdn=${TELEMETRY_GW_IP}
```

> **With Ambient Mesh:** If both clusters share the ambient mesh and the `solo-enterprise` namespace is enrolled on the relay cluster, use `mesh.internal` global hostnames instead of IPs:
> ```
> --set tunnel.fqdn=solo-enterprise-ui.solo-enterprise.mesh.internal
> --set telemetry.fqdn=solo-enterprise-telemetry-gateway.solo-enterprise.mesh.internal
> ```
>
> **Without Ambient (Kind/bare-metal):** Use the LoadBalancer IPs directly.

Verify pods:
```bash
kubectl --context ${CONTEXT2} -n solo-enterprise get pods
```

Expected:
```
NAME                                     READY   STATUS    RESTARTS   AGE
solo-enterprise-relay-xxxxxxxxxx-xxxxx   2/2     Running   0          30s
solo-enterprise-telemetry-collector-0    1/1     Running   0          30s
```

## Step 4: Verify Connectivity

```bash
# Tunnel connection (management cluster)
kubectl --context ${CONTEXT1} -n solo-enterprise logs deploy/solo-enterprise-ui -c tunnel-server --tail=5
# Expected: "storing cluster connection for ${CLUSTER2}"

# Registered clusters
kubectl --context ${CONTEXT1} -n solo-enterprise logs deploy/solo-enterprise-ui -c ui-backend | grep "knownClusters" | tail -1
# Expected: knownClusters %vmap[cluster1:{} cluster2:{}]

# West telemetry forwarding (no OTLP errors)
kubectl --context ${CONTEXT2} -n solo-enterprise logs solo-enterprise-telemetry-collector-0 --tail=3
# Expected: "Everything is ready. Begin running and processing data."
```

## Step 5: Access the UI

```bash
export UI_ADDRESS=http://$(kubectl --context ${CONTEXT1} get svc -n solo-enterprise solo-enterprise-ui \
  -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo ${UI_ADDRESS}
```

Open the URL in your browser. The service graph should show workloads from both clusters.

---

## Troubleshooting

### ClickHouse Handshake Errors at Startup

```
error: "handshake: failed to read packet from ...9000: read: EOF"
```

This is a startup race condition — the collector starts before ClickHouse is ready. The collector retries automatically. If errors persist after 2+ minutes, restart the collector:

```bash
kubectl --context ${CONTEXT1} -n solo-enterprise delete pod solo-enterprise-telemetry-collector-0
```

### West Collector OTLP Errors

```
error: "rpc error: code = Unavailable desc = connection error"
```

The west collector can't reach the east telemetry gateway. Check:
1. Telemetry gateway service has a LoadBalancer IP: `kubectl --context ${CONTEXT1} -n solo-enterprise get svc solo-enterprise-telemetry-gateway`
2. Network connectivity between clusters (Docker bridge for Kind, VPC peering for cloud)
3. If using `mesh.internal` hostnames, verify the relay namespace is ambient-enrolled

### UI Shows No Clusters

The UI backend watches `KubernetesCluster` CRs. If clusters don't appear:
1. Verify CRs exist: `kubectl --context ${CONTEXT1} get kubernetesclusters.platform.solo.io -n solo-enterprise`
2. Restart the UI: `kubectl --context ${CONTEXT1} -n solo-enterprise rollout restart deploy/solo-enterprise-ui`
3. Check logs: `kubectl --context ${CONTEXT1} -n solo-enterprise logs deploy/solo-enterprise-ui -c ui-backend | grep knownClusters`

### solo-enterprise Namespace and Ambient

**Do NOT enroll** `solo-enterprise` in ambient mesh. ztunnel intercepts:
- ClickHouse native protocol (port 9000) — same port as HBONE tunnel
- OTel OTLP receiver (port 4316) — raw TCP, not HTTP

Verify no ambient label:
```bash
kubectl get ns solo-enterprise -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}'
# Should return empty
```

---

## Cleanup

```bash
# Relay cluster
helm uninstall solo-relay -n solo-enterprise --kube-context ${CONTEXT2}
kubectl delete namespace solo-enterprise --context ${CONTEXT2}

# Management cluster
helm uninstall solo-management -n solo-enterprise --kube-context ${CONTEXT1}
kubectl delete namespace solo-enterprise --context ${CONTEXT1}
```

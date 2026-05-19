# Multicluster Ambient Mesh - Install Guide

## Step 1: Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml --context $CTX_EAST
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml --context $CTX_WEST
```

## Step 2: Install Istio Base

```bash
for CTX in $CTX_EAST $CTX_WEST; do
  helm upgrade -i istio-base oci://${HELM_REPO}/base \
    --version ${ISTIO_VERSION} \
    --namespace istio-system \
    --kube-context $CTX \
    --set profile=ambient
done
```

## Step 3: Install istiod

Each cluster gets a unique `trustDomain`, `clusterName`, and `network`. Peering is enabled for Solo's decentralized multicluster model.

### demo-east

```bash
helm upgrade -i istiod oci://${HELM_REPO}/istiod \
  --version ${ISTIO_VERSION} \
  --namespace istio-system \
  --kube-context $CTX_EAST \
  --set profile=ambient \
  --set global.hub=${REPO} \
  --set global.tag=${ISTIO_IMAGE} \
  --set global.multiCluster.clusterName=demo-east \
  --set global.network=demo-east \
  --set global.proxy.clusterDomain=cluster.local \
  --set meshConfig.trustDomain=demo-east.local \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE=true \
  --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_AUTO_ALLOCATE=true \
  --set platforms.peering.enabled=true \
  --set pilot.cni.enabled=true \
  --set pilot.cni.namespace=istio-system \
  --set env.PILOT_ENABLE_IP_AUTOALLOCATE=true \
  --set env.PILOT_SKIP_VALIDATE_TRUST_DOMAIN=true \
  --set env.DISABLE_LEGACY_MULTICLUSTER=true \
  --set license.value=${SOLO_ISTIO_LICENSE_KEY}
```

### demo-west

```bash
helm upgrade -i istiod oci://${HELM_REPO}/istiod \
  --version ${ISTIO_VERSION} \
  --namespace istio-system \
  --kube-context $CTX_WEST \
  --set profile=ambient \
  --set global.hub=${REPO} \
  --set global.tag=${ISTIO_IMAGE} \
  --set global.multiCluster.clusterName=demo-west \
  --set global.network=demo-west \
  --set global.proxy.clusterDomain=cluster.local \
  --set meshConfig.trustDomain=demo-west.local \
  --set meshConfig.accessLogFile=/dev/stdout \
  --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE=true \
  --set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_AUTO_ALLOCATE=true \
  --set platforms.peering.enabled=true \
  --set pilot.cni.enabled=true \
  --set pilot.cni.namespace=istio-system \
  --set env.PILOT_ENABLE_IP_AUTOALLOCATE=true \
  --set env.PILOT_SKIP_VALIDATE_TRUST_DOMAIN=true \
  --set env.DISABLE_LEGACY_MULTICLUSTER=true \
  --set license.value=${SOLO_ISTIO_LICENSE_KEY}
```

### Key istiod values explained

| Setting | Purpose |
|---|---|
| `platforms.peering.enabled` | Enables Solo's decentralized peering (no remote API server access needed) |
| `trustDomain` | Unique per-cluster for identity-based AuthZ (e.g., `demo-east.local`) |
| `global.network` | Network identifier for cross-cluster routing decisions |
| `DISABLE_LEGACY_MULTICLUSTER` | Prevents community Istio remote-secret mechanism |
| `PILOT_ENABLE_IP_AUTOALLOCATE` | Auto-allocates VIPs for ServiceEntries (enables mesh.internal hostnames) |
| `PILOT_SKIP_VALIDATE_TRUST_DOMAIN` | Allows cross-trust-domain mTLS |

## Step 4: Install istio-cni

```bash
for CTX in $CTX_EAST $CTX_WEST; do
  helm upgrade -i istio-cni oci://${HELM_REPO}/cni \
    --version ${ISTIO_VERSION} \
    --namespace istio-system \
    --kube-context $CTX \
    --set profile=ambient \
    --set global.hub=${REPO} \
    --set global.tag=${ISTIO_IMAGE} \
    --set ambient.dnsCapture=true \
    --set excludeNamespaces='{istio-system,kube-system}'
done
```

## Step 5: Install ztunnel

### demo-east

```bash
helm upgrade -i ztunnel oci://${HELM_REPO}/ztunnel \
  --version ${ISTIO_VERSION} \
  --namespace istio-system \
  --kube-context $CTX_EAST \
  --set profile=ambient \
  --set hub=${REPO} \
  --set tag=${ISTIO_IMAGE} \
  --set multiCluster.clusterName=demo-east \
  --set network=demo-east \
  --set variant=distroless \
  --set env.L7_ENABLED=true \
  --set env.SKIP_VALIDATE_TRUST_DOMAIN=true
```

### demo-west

```bash
helm upgrade -i ztunnel oci://${HELM_REPO}/ztunnel \
  --version ${ISTIO_VERSION} \
  --namespace istio-system \
  --kube-context $CTX_WEST \
  --set profile=ambient \
  --set hub=${REPO} \
  --set tag=${ISTIO_IMAGE} \
  --set multiCluster.clusterName=demo-west \
  --set network=demo-west \
  --set variant=distroless \
  --set env.L7_ENABLED=true \
  --set env.SKIP_VALIDATE_TRUST_DOMAIN=true
```

## Step 6: Label Namespaces for Network Topology

```bash
kubectl label namespace istio-system topology.istio.io/network=demo-east --context $CTX_EAST
kubectl label namespace istio-system topology.istio.io/network=demo-west --context $CTX_WEST
```

## Step 7: Create East-West Gateways

```bash
istioctl multicluster expose --namespace istio-eastwest --context $CTX_EAST --generate | kubectl apply -f - --context $CTX_EAST
istioctl multicluster expose --namespace istio-eastwest --context $CTX_WEST --generate | kubectl apply -f - --context $CTX_WEST
```

Wait for LoadBalancer IPs (requires `cloud-provider-kind` or equivalent):

```bash
kubectl get svc -n istio-eastwest --context $CTX_EAST
kubectl get svc -n istio-eastwest --context $CTX_WEST
```

## Step 8: Link Clusters

```bash
# Pre-check
istioctl multicluster check --precheck --contexts="${CTX_EAST},${CTX_WEST}"

# Link (creates bi-directional peering)
istioctl multicluster link --namespace istio-eastwest --contexts="${CTX_EAST},${CTX_WEST}"
```

## Step 9: Verify

```bash
# Full multicluster check
istioctl multicluster check --contexts="${CTX_EAST},${CTX_WEST}"
```

Expected output (all green):
```
✅ Clusters linked: demo-east ↔ demo-west
✅ Connected to demo-west via <LB_IP>
✅ Connected to demo-east via <LB_IP>
✅ Compatible intermediate certificates
```

```bash
# Verify all pods running
kubectl get pods -n istio-system --context $CTX_EAST
kubectl get pods -n istio-system --context $CTX_WEST
```

Expected pods per cluster: istiod, ztunnel (DaemonSet), istio-cni (DaemonSet)

```bash
# Verify east-west gateway pods
kubectl get pods -n istio-eastwest --context $CTX_EAST
kubectl get pods -n istio-eastwest --context $CTX_WEST
```

Next: [02_deploy_apps.md](02_deploy_apps.md)

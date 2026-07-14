# Multicluster Ambient Mesh — Install Guide

## Step 1: Gateway API CRDs

KGateway 2.2.x requires Gateway API v1.5.1:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml --context $CTX_EAST
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml --context $CTX_WEST
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

## Step 7: Create Remote Secrets

Remote secrets give each cluster's istiod read access to the other cluster's API server for endpoint discovery.

```bash
EAST_DOCKER_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' demo-east-control-plane)
WEST_DOCKER_IP=$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' demo-west-control-plane)
```

```bash
istioctl create-remote-secret --context $CTX_EAST --name demo-east --server https://${EAST_DOCKER_IP}:6443 2>&1 | grep -v "^warn:" | kubectl apply --context $CTX_WEST -f -
istioctl create-remote-secret --context $CTX_WEST --name demo-west --server https://${WEST_DOCKER_IP}:6443 2>&1 | grep -v "^warn:" | kubectl apply --context $CTX_EAST -f -
```

The `--server` flag with the Docker bridge IP is required because Kind's default kubeconfig uses `127.0.0.1`, which doesn't work cross-cluster. The `grep -v "^warn:"` strips a warning line that corrupts the YAML output.

## Step 8: Install Peering Chart (East-West Gateways)

The peering helm chart deploys east-west gateways and configures cross-cluster connectivity. This replaces both `istioctl multicluster expose` and `istioctl multicluster link`.

First install on both clusters without remote configuration (to create the EW gateway services and get their LB IPs):

```bash
for CTX in $CTX_EAST $CTX_WEST; do
  helm upgrade -i peering oci://${HELM_REPO}/peering \
    --version ${ISTIO_VERSION} \
    --namespace istio-eastwest \
    --create-namespace \
    --kube-context $CTX \
    --set global.hub=${REPO} \
    --set global.tag=${ISTIO_IMAGE} \
    --set profile=ambient \
    --set "dataplaneServiceTypes={loadbalancer}"
done
```

Wait for LoadBalancer IPs (requires `cloud-provider-kind` running):

```bash
kubectl get svc -n istio-eastwest --context $CTX_EAST -w
kubectl get svc -n istio-eastwest --context $CTX_WEST -w
```

Capture the EW gateway IPs:

```bash
EAST_EW_IP=$(kubectl get svc -n istio-eastwest istio-eastwest --context $CTX_EAST -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
WEST_EW_IP=$(kubectl get svc -n istio-eastwest istio-eastwest --context $CTX_WEST -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "East EW: $EAST_EW_IP, West EW: $WEST_EW_IP"
```

## Step 9: Configure Cross-Cluster Peering

Upgrade the peering chart on each cluster with the remote cluster's EW gateway address.

### demo-east (peers with west)

```bash
helm upgrade -i peering oci://${HELM_REPO}/peering \
  --version ${ISTIO_VERSION} \
  --namespace istio-eastwest \
  --kube-context $CTX_EAST \
  --set global.hub=${REPO} \
  --set global.tag=${ISTIO_IMAGE} \
  --set profile=ambient \
  --set "dataplaneServiceTypes={loadbalancer}" \
  --set remote[0].name=demo-west \
  --set remote[0].address=${WEST_EW_IP} \
  --set remote[0].network=demo-west \
  --set remote[0].trustDomain=cluster.local
```

### demo-west (peers with east)

```bash
helm upgrade -i peering oci://${HELM_REPO}/peering \
  --version ${ISTIO_VERSION} \
  --namespace istio-eastwest \
  --kube-context $CTX_WEST \
  --set global.hub=${REPO} \
  --set global.tag=${ISTIO_IMAGE} \
  --set profile=ambient \
  --set "dataplaneServiceTypes={loadbalancer}" \
  --set remote[0].name=demo-east \
  --set remote[0].address=${EAST_EW_IP} \
  --set remote[0].network=demo-east \
  --set remote[0].trustDomain=cluster.local
```

### Why `trustDomain: cluster.local`?

The `trustDomain` in the peering remote items must match the SPIFFE trust domain in the actual certificates. Even though `meshConfig.trustDomain` is set to `demo-east.local` / `demo-west.local`, istiod signs workload certificates with `cluster.local` as the SPIFFE trust domain (because the `cacerts` secret's intermediate CA uses `cluster.local`). Setting the remote `trustDomain` to the meshConfig value causes a TLS handshake failure:

```
peer did not present the expected SAN (spiffe://demo-west.local/ns/istio-eastwest/sa/istio-eastwest),
got spiffe://cluster.local/ns/istio-eastwest/sa/istio-eastwest
```

### Why the peering chart instead of `istioctl multicluster expose/link`?

- `istioctl multicluster expose` uses the `kube-eastwest` Go template inside istiod. In Solo Istio 1.29.1, this template was missing, causing `no "kube-eastwest" template defined` errors. Fixed in 1.29.3, but the peering chart is the recommended Solo approach regardless.
- `istioctl multicluster link` can fail with version mismatches between istioctl and istiod.
- The peering chart is declarative (helm-managed) and integrates with Solo's decentralized peering model (`platforms.peering.enabled=true`).

## Step 10: Verify

```bash
kubectl get pods -n istio-system --context $CTX_EAST
kubectl get pods -n istio-system --context $CTX_WEST
kubectl get pods -n istio-eastwest --context $CTX_EAST
kubectl get pods -n istio-eastwest --context $CTX_WEST
```

Expected pods per cluster: istiod, ztunnel (DaemonSet), istio-cni (DaemonSet), east-west gateway.

Check peering status:

```bash
istioctl multicluster check --contexts="${CTX_EAST},${CTX_WEST}"
```

Verify all helm releases are on the same version:

```bash
helm list -A --kube-context $CTX_EAST
helm list -A --kube-context $CTX_WEST
```

All Istio charts (base, istiod, cni, ztunnel, peering) should show the same version.

Next: [02_install_kgateway.md](02_install_kgateway.md)

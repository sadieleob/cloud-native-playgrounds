# Migration Tool

Convert Gloo Gateway v1 CRs to Enterprise kgateway 2.x in a browser UI.

**What it converts:** RouteOption → EKTP, VirtualHostOption → EKTP, GatewayParameters, AuthConfig, Upstream → Backend, Portal, ApiProduct, ApiSchemaDiscovery → ApiDoc, HTTPRoute (strips ExtensionRef filters), ReferenceGrant.

**Image:** `sadielio/migration-tool:latest` — Alpine-based, 0 Critical/High CVEs.

---

## Prerequisites

- Docker + kind + helm + kubectl
- Enterprise kgateway license key: `$GLOO_LICENSE_KEY`
- Enterprise kgateway portal license key: `$PORTAL_LICENSE_KEY` *(only needed if validating Portal CRs)*

---

## 1. Kind cluster

```bash
export CLUSTER_NAME=migration-tool
export KIND_IMAGE=kindest/node:v1.33.1@sha256:050072256b9a903bd914c0b2866828150cb229cea0efe5892e2b644d5dd3b34f

kind create cluster --name $CLUSTER_NAME --image $KIND_IMAGE

export CONTEXT=kind-$CLUSTER_NAME
kubectl --context $CONTEXT get nodes
```

---

## 2. Gateway API CRDs (experimental)

kgateway watches `v1alpha2.TLSRoute` — use the **experimental** bundle.

> **Note:** Use `--server-side` apply. The HTTPRoute CRD exceeds the 262KB client-side annotation limit and will error without it.

```bash
kubectl --context $CONTEXT apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
```

---

## 3. Enterprise kgateway 2.3.0

```bash
export KGW_VERSION=2.3.0
export KGW_NAMESPACE=kgateway-system

helm upgrade -i enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --version $KGW_VERSION \
  --namespace $KGW_NAMESPACE --create-namespace \
  --kube-context $CONTEXT

helm upgrade -i enterprise-kgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
  --version $KGW_VERSION \
  --namespace $KGW_NAMESPACE \
  --kube-context $CONTEXT \
  --set-string licensing.licenseKey=$GLOO_LICENSE_KEY
```

Verify:

```bash
kubectl --context $CONTEXT -n $KGW_NAMESPACE get pods
# enterprise-kgateway, ext-auth-service, rate-limiter
```

---

## 4. Portal 2.3.0 *(optional — enables dry-run validation of Portal CRs)*

```bash
helm upgrade -i portal-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal-crds \
  --version $KGW_VERSION \
  --namespace portal-system --create-namespace \
  --kube-context $CONTEXT

helm upgrade -i portal \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal \
  --version $KGW_VERSION \
  --namespace portal-system \
  --kube-context $CONTEXT \
  --set licensing.licenseKey=$PORTAL_LICENSE_KEY
```

---

## 5. Gateway

> **Note:** The Helm chart auto-creates a `enterprise-kgateway` GatewayClass. The `k8s/gateway.yaml` uses that class — do not change `gatewayClassName`.

```bash
kubectl --context $CONTEXT apply -f k8s/gateway.yaml
kubectl --context $CONTEXT -n $KGW_NAMESPACE wait \
  --for=condition=Programmed gateway/http --timeout=60s
```

---

## 6. Migration tool

```bash
kubectl --context $CONTEXT apply -f k8s/migration-tool.yaml
kubectl --context $CONTEXT -n migration-tool rollout status deploy/migration-tool
```

Verify the route is accepted:

```bash
kubectl --context $CONTEXT get httproute migration-tool -n migration-tool
# PROGRAMMED True
```

---

## 7. Access

kgateway creates one proxy pod per Gateway. Port-forward to it using the gateway label:

```bash
PROXY_POD=$(kubectl --context $CONTEXT -n $KGW_NAMESPACE \
  get pod -l gateway.networking.k8s.io/gateway-name=http \
  -o jsonpath='{.items[0].metadata.name}')

kubectl --context $CONTEXT -n $KGW_NAMESPACE port-forward pod/$PROXY_POD 8080:8080
```

> **Tip:** If port 8080 is already in use, pick another: `port-forward pod/$PROXY_POD 9090:8080` and access at `http://migration-tool.localhost:9090/migration/tool/`.

Add to `/etc/hosts`:

```
127.0.0.1  migration-tool.localhost
```

Open: **http://migration-tool.localhost:8080/migration/tool/**

---

## Collecting a GGv1 snapshot

Run these against your GGv1 cluster (not the Kind cluster):

```bash
# Terminal 1
kubectl -n gloo-system port-forward deploy/gloo 9095:9095

# Terminal 2
curl -s http://localhost:9095/snapshots/input > gloo-input.json
```

Upload `gloo-input.json` via the **Upload** tab in the migration tool UI.

---

## Output

The tool returns all converted CRs as a single YAML bundle. Download it and review the **Warnings** panel for:

- `corsPolicyMergeSettings` — no equivalent in kgateway 2.x; manually duplicate gateway-level `exposeHeaders` into each per-route EKTP
- `basicAuth` — moved from AuthConfig to EKTP; credentials must be re-encoded as htpasswd
- Portal wildcard namespace — `namespace: "*"` not supported in 2.2.x, fixed in 2.3.x
- PortalParameters stub — fill in your PostgreSQL connection before applying

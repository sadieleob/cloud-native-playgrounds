# Install KGateway 2.2.4 Enterprise

Install on **demo-east only** (the primary ingress cluster).

## Step 1: Install CRDs

```bash
helm upgrade -i enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --create-namespace -n kgateway-system \
  --version ${KGW_VERSION} \
  --kube-context $CTX_EAST
```

## Step 2: Install KGateway Control Plane

The `KGW_ENABLE_ISTIO_INTEGRATION=true` flag is critical — without it, kgateway won't watch ServiceEntry resources and the `Hostname` backendRef won't resolve. It defaults to `false`.

```bash
helm upgrade -i enterprise-kgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway \
  -n kgateway-system \
  --version ${KGW_VERSION} \
  --set-string licensing.licenseKey=$GLOO_GATEWAY_LICENSE_KEY \
  --set controller.extraEnv.KGW_ENABLE_ISTIO_INTEGRATION=true \
  --kube-context $CTX_EAST
```

Verify:

```bash
kubectl get pods -n kgateway-system --context $CTX_EAST
kubectl get gatewayclass --context $CTX_EAST
```

Expected: `enterprise-kgateway` GatewayClass with controller `solo.io/enterprise-kgateway`.

## Step 3: Enroll kgateway-system in Ambient Mesh

```bash
kubectl label ns kgateway-system istio.io/dataplane-mode=ambient --context $CTX_EAST
```

This makes ztunnel intercept traffic from the kgateway proxy pod, securing outbound connections to backends with mTLS.

## Step 4: Create EnterpriseKgatewayParameters

When PeerAuthentication STRICT is active, external clients (no mesh identity) get rejected if ztunnel captures inbound traffic on the gateway proxy. The `bypass-inbound-capture` annotation tells ztunnel to only capture **outbound** connections.

```bash
kubectl apply --context $CTX_EAST -f manifests/kgateway-params.yaml
```

Or inline:

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayParameters
metadata:
  name: kgw-ambient-params
  namespace: kgateway-system
spec:
  kube:
    podTemplate:
      extraAnnotations:
        ambient.istio.io/bypass-inbound-capture: "true"
EOF
```

## Step 5: Create the Gateway

```bash
kubectl apply --context $CTX_EAST -f manifests/kgateway-gateway.yaml
```

Or inline:

```bash
kubectl apply --context $CTX_EAST -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: http
  namespace: kgateway-system
spec:
  gatewayClassName: enterprise-kgateway
  infrastructure:
    parametersRef:
      name: kgw-ambient-params
      group: enterprisekgateway.solo.io
      kind: EnterpriseKgatewayParameters
  listeners:
  - name: http
    port: 8080
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

## Step 6: Verify

```bash
kubectl get gateway http -n kgateway-system --context $CTX_EAST
```

Expected: `PROGRAMMED: True`

```bash
kubectl get pods -n kgateway-system --context $CTX_EAST
```

Expected: `http-*` proxy pod running with the `ambient.istio.io/bypass-inbound-capture: "true"` annotation.

```bash
export INGRESS_GW_ADDRESS=$(kubectl get svc -n kgateway-system http --context $CTX_EAST -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}")
echo $INGRESS_GW_ADDRESS
```

## Differences from GGv1

| What changed | GGv1 (1.20.10) | KGateway (2.2.4) |
|---|---|---|
| Helm chart | `glooe/gloo-ee` | OCI: `enterprise-kgateway` + `enterprise-kgateway-crds` |
| Namespace | `gloo-system` | `kgateway-system` |
| GatewayClass | `gloo-gateway` | `enterprise-kgateway` |
| Istio integration | `GG_AMBIENT_MULTINETWORK=true` env var | `KGW_ENABLE_ISTIO_INTEGRATION=true` helm value |
| Ambient pod config | N/A | `EnterpriseKgatewayParameters` with `bypass-inbound-capture` |
| Gateway parametersRef | Not needed | Required — wires the params to the proxy pod |

Next: [03_deploy_apps.md](03_deploy_apps.md)

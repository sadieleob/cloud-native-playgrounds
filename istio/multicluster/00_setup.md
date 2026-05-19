# Multicluster Ambient Mesh - Environment Setup

## Architecture Overview

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                  Shared Root CA Trust                     │
                    │         (EasyRSA Root → per-cluster intermediates)        │
                    └──────────────────────────────────────────────────────────┘

    ┌───────────────────────────────┐           ┌───────────────────────────────┐
    │        demo-east           │           │        demo-west           │
    │    (Kind cluster, K8s 1.32)   │           │    (Kind cluster, K8s 1.32)   │
    │                               │           │                               │
    │  ┌─────────┐  ┌───────────┐  │  Peering  │  ┌─────────┐  ┌───────────┐  │
    │  │ istiod  │◄─┼───────────┼──┼───────────┼──┤ istiod  │  │           │  │
    │  └────┬────┘  │ EW Gateway│  │  (xDS/    │  └────┬────┘  │ EW Gateway│  │
    │       │       │ (LB)      │◄─┼──mTLS)────┼──────►│       │ (LB)      │  │
    │  ┌────┴────┐  └───────────┘  │           │  ┌────┴────┐  └───────────┘  │
    │  │ ztunnel │                  │  HBONE    │  │ ztunnel │                  │
    │  │ (L4)    │◄─┼───────────┼──┼───────────┼──┤ (L4)    │                  │
    │  └────┬────┘  │           │  │           │  └────┬────┘                  │
    │       │       │           │  │           │       │                        │
    │  ┌────┴────┐  │           │  │           │  ┌────┴────┐                  │
    │  │waypoint │  │           │  │           │  │waypoint │                  │
    │  │ (L7)    │  │           │  │           │  │ (L7)    │                  │
    │  └────┬────┘  │           │  │           │  └────┬────┘                  │
    │       │       │           │  │           │       │                        │
    │  ┌────┴────┐  │           │  │           │  ┌────┴────┐                  │
    │  │ nginx   │  │           │  │           │  │ nginx   │                  │
    │  │ (EAST)  │  │           │  │           │  │ (WEST)  │                  │
    │  └─────────┘  │           │  │           │  └─────────┘                  │
    └───────────────────────────────┘           └───────────────────────────────┘
```

**Key components:**
- **ztunnel** (L4 DaemonSet): Transparent mTLS for all ambient-enrolled workloads
- **Waypoint proxy** (L7): Enforces AuthorizationPolicies per-service
- **East-West Gateway**: Cross-cluster HBONE tunnel endpoint
- **Peering**: Solo's decentralized push-based model (no remote API server access)

## Prerequisites

| Requirement | Value |
|---|---|
| Solo Istio version | 1.29.1-solo |
| Kubernetes version | v1.32.5 |
| Kind image | `kindest/node:v1.32.5` |
| Gateway API CRDs | v1.2.1 |
| License | `$GLOO_MESH_LICENSE_KEY` (Solo Enterprise) |
| LoadBalancer | `cloud-provider-kind` service running |

## Environment Variables

```bash
export ISTIO_VERSION=1.29.1
export ISTIO_IMAGE=${ISTIO_VERSION}-solo
export REPO=us-docker.pkg.dev/soloio-img/istio
export HELM_REPO=us-docker.pkg.dev/soloio-img/istio-helm
export SOLO_ISTIO_LICENSE_KEY=$GLOO_MESH_LICENSE_KEY
export PATH=${HOME}/.istioctl/bin:${PATH}
export CTX_EAST=kind-demo-east
export CTX_WEST=kind-demo-west
```

## Install Solo istioctl

```bash
bash <(curl -sSfL https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-mesh/install-istioctl.sh)
istioctl version --remote=false
# Expected: 1.29.1-solo
```

## Create Kind Clusters

```bash
cat <<EOF | kind create cluster --name demo-east --image kindest/node:v1.32.5 --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
- role: worker
EOF

cat <<EOF | kind create cluster --name demo-west --image kindest/node:v1.32.5 --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
nodes:
- role: control-plane
- role: worker
EOF
```

## Certificate Setup (Shared Root CA)

Both clusters share a root CA with per-cluster intermediate certificates. This enables cross-cluster mTLS trust.

**Certificate structure:**
```
Root CA (CN=Istio Ambient Root CA)
├── ambient1-intermediate (for demo-east)
│   ├── ca-cert.pem    (intermediate cert)
│   ├── ca-key.pem     (intermediate key)
│   ├── root-cert.pem  (root cert)
│   └── cert-chain.pem (intermediate + root chain)
└── ambient2-intermediate (for demo-west)
    ├── ca-cert.pem
    ├── ca-key.pem
    ├── root-cert.pem
    └── cert-chain.pem
```

Cert files located at:
- East: `repro-scripts/istio-ambient-multicluster/easyrsa-ambient1/`
- West: `repro-scripts/istio-ambient-multicluster/easyrsa-ambient2/`

```bash
CERT_BASE=/mnt/extra/mycluster/kind/repro-scripts/istio-ambient-multicluster

# East cluster
kubectl create ns istio-system --context $CTX_EAST
kubectl create secret generic cacerts -n istio-system --context $CTX_EAST \
  --from-file=ca-cert.pem=${CERT_BASE}/easyrsa-ambient1/ca-cert.pem \
  --from-file=ca-key.pem=${CERT_BASE}/easyrsa-ambient1/ca-key.pem \
  --from-file=root-cert.pem=${CERT_BASE}/easyrsa-ambient1/root-cert.pem \
  --from-file=cert-chain.pem=${CERT_BASE}/easyrsa-ambient1/cert-chain.pem

# West cluster
kubectl create ns istio-system --context $CTX_WEST
kubectl create secret generic cacerts -n istio-system --context $CTX_WEST \
  --from-file=ca-cert.pem=${CERT_BASE}/easyrsa-ambient2/ca-cert.pem \
  --from-file=ca-key.pem=${CERT_BASE}/easyrsa-ambient2/ca-key.pem \
  --from-file=root-cert.pem=${CERT_BASE}/easyrsa-ambient2/root-cert.pem \
  --from-file=cert-chain.pem=${CERT_BASE}/easyrsa-ambient2/cert-chain.pem
```

Next: [01_install_ambient.md](01_install_ambient.md)

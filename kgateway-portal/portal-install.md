# Portal Demo on Solo Enterprise for kgateway 2.2.0

Complete deployment guide — Kind cluster creation through working portal with Okta OIDC.

Cluster context: `kind-portal-demo`

---

## 1. Kind Cluster

```bash
export CLUSTER_NAME=portal-demo
export KIND_IMAGE=kindest/node:v1.33.1@sha256:050072256b9a903bd914c0b2866828150cb229cea0efe5892e2b644d5dd3b34f

kind create cluster --config -<<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
nodes:
- role: control-plane
  image: $KIND_IMAGE
- role: worker
  image: $KIND_IMAGE
networking:
  disableDefaultCNI: false
EOF
```

Verify:
```bash
export CONTEXT=kind-$CLUSTER_NAME
kubectl --context $CONTEXT get nodes
```

## 2. K8s Gateway API CRDs v1.5.1 (Experimental)

**IMPORTANT:** Use the **experimental** channel, not standard. kgateway 2.2.0 watches
`v1alpha2.TLSRoute` which is only in the experimental bundle. Install **BEFORE** kgateway-crds
helm chart so it preserves the alpha version serving flags.

```bash
kubectl --context $CONTEXT apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
```

### Fix if kgateway-crds was installed first

If the controller is stuck with `watch error: failed to list *v1alpha2.TLSRoute`:
```bash
kubectl --context $CONTEXT get crd tlsroutes.gateway.networking.k8s.io -o json \
  | jq '(.spec.versions[] | select(.name == "v1alpha2" or .name == "v1alpha3")).served = true' \
  | kubectl --context $CONTEXT replace -f -
```

## 3. kgateway Enterprise 2.2.0

```bash
export KGW_NAMESPACE=kgateway-system
export KGW_VERSION=2.2.0

helm upgrade -i enterprise-kgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/enterprise-kgateway-crds \
  --version $KGW_VERSION \
  --namespace $KGW_NAMESPACE \
  --create-namespace \
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
# Expected: enterprise-kgateway, ext-auth-service, ext-cache, rate-limiter
```

## 4. Portal CRDs + Controller

Portal is a separate helm chart in 2.2.0 (not bundled with kgateway).

```bash
export PORTAL_NAMESPACE=portal-system
export PORTAL_VERSION=2.2.0

helm upgrade -i portal-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal-crds \
  --version $PORTAL_VERSION \
  --namespace $PORTAL_NAMESPACE \
  --create-namespace \
  --kube-context $CONTEXT

helm upgrade -i portal \
  oci://us-docker.pkg.dev/solo-public/enterprise-kgateway/charts/portal \
  --version $PORTAL_VERSION \
  --namespace $PORTAL_NAMESPACE \
  --kube-context $CONTEXT \
  --set licensing.licenseKey=$GLOO_LICENSE_KEY
```

Verify:
```bash
kubectl --context $CONTEXT -n $PORTAL_NAMESPACE get pods
# Expected: portal-controller
```

## 5. Environment Variables

```bash
export CLUSTER_NAME=portal-demo
export CONTEXT=kind-$CLUSTER_NAME
export KGW_NAMESPACE=kgateway-system
export PORTAL_NAMESPACE=portal-system

# Okta OIDC
export OKTA_DOMAIN=integrator-4829064.okta.com
export OKTA_ISSUER_URL=https://$OKTA_DOMAIN/oauth2/default
export CLIENT_ID=<REDACTED_CLIENT_ID>
export CLIENT_SECRET="<REDACTED_CLIENT_SECRET>"

# Hosts
export PORTAL_HOST=portal.servebeer.com
export API_HOST=api.servebeer.com
```

## 6. TLS Secret

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: wildcard-servebeer-tls
  namespace: default
type: kubernetes.io/tls
data:
  tls.crt: $(cat wildcard.servebeer.com.crt | base64 -w0)
  tls.key: $(cat wildcard.servebeer.com.key | base64 -w0)
EOF
```

## 7. PortalParameters

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: portal.solo.io/v1alpha1
kind: PortalParameters
metadata:
  name: portal-params
  namespace: default
spec:
  store:
    memory: {}
EOF
```

## 8. Portal CR

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: portal.solo.io/v1alpha1
kind: Portal
metadata:
  name: demo-portal
  namespace: default
spec:
  parametersRef:
    name: portal-params
  visibility:
    public: true
  apiProductRefs:
  - name: tracks-api-product
    namespace: default
  - name: petstore-api-product
    namespace: default
EOF
```

## 9. Gateway

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: portal-gateway
  namespace: default
spec:
  gatewayClassName: enterprise-kgateway
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-servebeer-tls
        namespace: default
    allowedRoutes:
      namespaces:
        from: All
EOF
```

## 10. Portal Frontend (UI)

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portal-ui
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-ui
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: portal-ui
  template:
    metadata:
      labels:
        app: portal-ui
    spec:
      serviceAccountName: portal-ui
      securityContext:
        runAsNonRoot: true
        runAsUser: 10101
      containers:
      - name: portal-ui
        image: gcr.io/solo-public/docs/portal-frontend:v0.1.8
        imagePullPolicy: IfNotPresent
        ports:
        - name: http
          containerPort: 4000
          protocol: TCP
        env:
        - name: VITE_PORTAL_SERVER_URL
          value: "https://$PORTAL_HOST/v1"
        - name: VITE_APPLIED_OIDC_AUTH_CODE_CONFIG
          value: "true"
        - name: VITE_OIDC_AUTH_CODE_CONFIG_CALLBACK_PATH
          value: "/v1/login"
        - name: VITE_OIDC_AUTH_CODE_CONFIG_LOGOUT_PATH
          value: "/v1/logout"
        livenessProbe:
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: portal-ui
  namespace: default
spec:
  type: ClusterIP
  ports:
  - port: 4000
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: portal-ui
EOF
```

## 11. HTTPRoutes

### Portal Backend (`/v1/`)
```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal-backend
  namespace: default
spec:
  parentRefs:
  - name: portal-gateway
    namespace: default
  hostnames:
  - "$PORTAL_HOST"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/
    backendRefs:
    - name: portal-demo-portal
      namespace: default
      port: 8080
EOF
```

### Portal Frontend (catch-all `/`)
```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal-frontend
  namespace: default
spec:
  parentRefs:
  - name: portal-gateway
    namespace: default
  hostnames:
  - "$PORTAL_HOST"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: portal-ui
      namespace: default
      port: 4000
EOF
```

### Login/Logout (`/v1/login`, `/v1/logout`)
```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal-login
  namespace: default
spec:
  parentRefs:
  - name: portal-gateway
    namespace: default
  hostnames:
  - "$PORTAL_HOST"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/login
    - path:
        type: PathPrefix
        value: /v1/logout
    backendRefs:
    - name: portal-demo-portal
      namespace: default
      port: 8080
EOF
```

## 12. Okta OIDC Authentication

### 12a. OIDC Secret

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: portal-oidc-okta
  namespace: default
type: extauth.solo.io/oauth
stringData:
  client-id: "$CLIENT_ID"
  client-secret: "$CLIENT_SECRET"
EOF
```

### 12b. AuthConfig

**IMPORTANT:** Use `idTokenHeader`, NOT `accessTokenHeader`. The portal backend needs the
ID token (contains `email`, `groups` claims). Using `accessTokenHeader` causes login to appear
to succeed (OIDC flow completes, session cookie set) but the portal shows the user as
unauthenticated because the backend receives the access token which lacks identity claims.

Set `cookieOptions.notSecure: true` for Kind/local environments.

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: portal-oidc-okta
  namespace: default
spec:
  configs:
  - oauth2:
      oidcAuthorizationCode:
        appUrl: "https://$PORTAL_HOST"
        callbackPath: /v1/login
        logoutPath: /v1/logout
        clientId: "$CLIENT_ID"
        clientSecretRef:
          name: portal-oidc-okta
          namespace: default
        issuerUrl: "$OKTA_ISSUER_URL"
        session:
          failOnFetchFailure: true
          cookieOptions:
            notSecure: true
          cookie:
            allowRefreshing: true
        scopes:
        - openid
        - profile
        - groups
        - email
        headers:
          idTokenHeader: id_token
EOF
```

### 12c. GatewayExtension (ext-auth timeout)

Default ext-auth timeout is 200ms — too short for OIDC token exchange with Okta.
Without this, the callback fails with `"error exchanging token": "context canceled"`.

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.kgateway.dev/v1alpha1
kind: GatewayExtension
metadata:
  name: extauth-timeout
  namespace: $KGW_NAMESPACE
spec:
  type: ExtAuth
  extAuth:
    grpcService:
      requestTimeout: 10s
      backendRef:
        name: ext-auth-service-enterprise-kgateway
        namespace: $KGW_NAMESPACE
        port: 8083
EOF
```

### 12d. OIDC TrafficPolicies

Two policies needed:
- **portal-oidc** → targets `portal-login` route (handles OIDC redirect + callback)
- **portal-backend-oidc** → targets `portal-backend` route (validates session cookie, forwards `id_token` header on `/v1/*` calls like `/v1/me`, `/v1/teams`)

Without `portal-backend-oidc`, the portal backend never receives the `id_token` header and
can't identify the logged-in user.

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: portal-oidc
  namespace: default
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: portal-login
  entExtAuth:
    extensionRef:
      name: extauth-timeout
      namespace: $KGW_NAMESPACE
    authConfigRef:
      name: portal-oidc-okta
      namespace: default
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: portal-backend-oidc
  namespace: default
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: portal-backend
  entExtAuth:
    extensionRef:
      name: extauth-timeout
      namespace: $KGW_NAMESPACE
    authConfigRef:
      name: portal-oidc-okta
      namespace: default
EOF
```

## 13. Sample Apps

```bash
kubectl --context $CONTEXT create ns tracks
kubectl --context $CONTEXT create ns users
kubectl --context $CONTEXT create ns pets
kubectl --context $CONTEXT create ns store
kubectl --context $CONTEXT apply -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-gateway/portal/tracks-api.yaml
kubectl --context $CONTEXT apply -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-gateway/portal/users-api.yaml
kubectl --context $CONTEXT apply -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-gateway/portal/pets-api.yaml
kubectl --context $CONTEXT apply -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/gloo-gateway/portal/store-api.yaml
```

## 14. API HTTPRoutes

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tracks-route
  namespace: default
spec:
  parentRefs:
  - name: portal-gateway
    namespace: default
  hostnames:
  - "$API_HOST"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /tracks
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: tracks-rest-api
      namespace: tracks
      port: 5000
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: petstore-route
  namespace: default
spec:
  parentRefs:
  - name: portal-gateway
    namespace: default
  hostnames:
  - "$API_HOST"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /users
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: users-rest-api
      namespace: users
      port: 5000
  - matches:
    - path:
        type: PathPrefix
        value: /pets
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: pets-rest-api
      namespace: pets
      port: 5000
  - matches:
    - path:
        type: PathPrefix
        value: /store
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
    backendRefs:
    - name: store-rest-api
      namespace: store
      port: 5000
EOF
```

## 15. ReferenceGrants (cross-namespace)

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: tracks-rg
  namespace: tracks
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: users-rg
  namespace: users
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: pets-rg
  namespace: pets
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default
  to:
  - group: ""
    kind: Service
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: store-rg
  namespace: store
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default
  to:
  - group: ""
    kind: Service
EOF
```

## 16. ApiDocs

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: portal.solo.io/v1alpha1
kind: ApiDoc
metadata:
  name: tracks-apidoc
  namespace: tracks
spec:
  source:
    manual:
      content: |
        {
          "openapi": "3.0.0",
          "info": { "title": "Tracks API", "version": "1.0.0", "description": "Catstronauts Tracks API" },
          "paths": {
            "/": { "get": { "summary": "List all tracks", "responses": { "200": { "description": "Success" } } } },
            "/{id}": { "get": { "summary": "Get track by ID", "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "string"}}], "responses": { "200": { "description": "Success" } } } }
          }
        }
  servedBy:
    name: tracks-rest-api
    namespace: tracks
    port: 5000
---
apiVersion: portal.solo.io/v1alpha1
kind: ApiDoc
metadata:
  name: petstore-users-apidoc
  namespace: users
spec:
  source:
    manual:
      content: |
        {
          "openapi": "3.0.0",
          "info": { "title": "Users API", "version": "1.0.0", "description": "Petstore Users API" },
          "paths": {
            "/": { "get": { "summary": "List users", "responses": { "200": { "description": "Success" } } } }
          }
        }
  servedBy:
    name: users-rest-api
    namespace: users
    port: 5000
---
apiVersion: portal.solo.io/v1alpha1
kind: ApiDoc
metadata:
  name: petstore-pets-apidoc
  namespace: pets
spec:
  source:
    manual:
      content: |
        {
          "openapi": "3.0.0",
          "info": { "title": "Pets API", "version": "1.0.0", "description": "Petstore Pets API" },
          "paths": {
            "/": { "get": { "summary": "List pets", "responses": { "200": { "description": "Success" } } } }
          }
        }
  servedBy:
    name: pets-rest-api
    namespace: pets
    port: 5000
---
apiVersion: portal.solo.io/v1alpha1
kind: ApiDoc
metadata:
  name: petstore-store-apidoc
  namespace: store
spec:
  source:
    manual:
      content: |
        {
          "openapi": "3.0.0",
          "info": { "title": "Store API", "version": "1.0.0", "description": "Petstore Store API" },
          "paths": {
            "/inventory": { "get": { "summary": "Returns pet inventories", "responses": { "200": { "description": "Success" } } } }
          }
        }
  servedBy:
    name: store-rest-api
    namespace: store
    port: 5000
EOF
```

## 17. ApiProducts

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: portal.solo.io/v1alpha1
kind: ApiProduct
metadata:
  name: tracks-api-product
  namespace: default
spec:
  id: tracks
  displayName: "Tracks API"
  customMetadata:
    category: "Catstronauts"
  versions:
  - name: v1
    targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: tracks-route
    openApiMetadata:
      title: "Tracks API"
      description: "Catstronauts Tracks service"
---
apiVersion: portal.solo.io/v1alpha1
kind: ApiProduct
metadata:
  name: petstore-api-product
  namespace: default
spec:
  id: petstore
  displayName: "Petstore API"
  customMetadata:
    category: "Petstore"
  versions:
  - name: v1
    targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: petstore-route
    openApiMetadata:
      title: "Petstore API"
      description: "Users, Pets, and Store services"
EOF
```

## 18. API Key Authentication (portalAuth)

```bash
kubectl --context $CONTEXT apply -f- <<EOF
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: portal-api-auth
  namespace: default
spec:
  configs:
  - name: portalApiAuth
    portalAuth:
      url: http://portal-demo-portal.default.svc.cluster.local:8080
      cacheDuration: 10s
      apiKeyHeader: "api-key"
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: tracks-auth
  namespace: default
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: tracks-route
  entExtAuth:
    authConfigRef:
      name: portal-api-auth
      namespace: default
  cors:
    allowCredentials: true
    allowHeaders:
    - "*"
    allowMethods:
    - GET
    allowOrigins:
    - "*"
---
apiVersion: enterprisekgateway.solo.io/v1alpha1
kind: EnterpriseKgatewayTrafficPolicy
metadata:
  name: petstore-auth
  namespace: default
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: petstore-route
  entExtAuth:
    authConfigRef:
      name: portal-api-auth
      namespace: default
  cors:
    allowCredentials: true
    allowHeaders:
    - "*"
    allowMethods:
    - GET
    allowOrigins:
    - "*"
EOF
```

## 19. Verify

```bash
kubectl --context $CONTEXT get pods -A
kubectl --context $CONTEXT get gateway,httproute -A
kubectl --context $CONTEXT get authconfig,enterprisekgatewaytrafficpolicy,gatewayextension -A
kubectl --context $CONTEXT get portal,apiproduct,apidoc,portalparameters -A
kubectl --context $CONTEXT get referencegrant -A
```

---

## Troubleshooting Notes

### Login flow: context canceled on token exchange
Default ext-auth gRPC timeout is 200ms. Okta token exchange takes longer.
Fix: GatewayExtension with `requestTimeout: 10s` (section 12c), referenced by TrafficPolicies.
Verify in Envoy: `x-envoy-expected-rq-timeout-ms:[10000]` in ext-auth logs.
Envoy admin is on port **19000** (not 15000).

### Login succeeds but user appears unauthenticated
Two causes found during setup:
1. `accessTokenHeader` used instead of `idTokenHeader` — access token lacks email/groups claims
2. Missing TrafficPolicy on portal-backend route — ext-auth not forwarding `id_token` header on `/v1/*` API calls

### Admin vs regular users
In 2.2.0 portal, users with `groups: ["admin"]` in their ID token are portal admins.
Admins can approve/reject subscriptions but **cannot** create teams or apps.
Regular users (no `admin` group) create teams, apps, and request subscriptions.

### notSecure cookie option
Set `cookieOptions.notSecure: true` for Kind/local environments. Without it, session cookies
may not be sent back by the browser on OIDC redirect.

---

## GGv1 → kgateway 2.2.0 Portal Mapping

| GGv1 Concept | kgateway 2.2.0 Equivalent |
|---|---|
| Portal baked into gloo-ee helm chart | Separate `portal-crds` + `portal` helm charts |
| `portal.gloo.solo.io/v1` CRDs | `portal.solo.io/v1alpha1` CRDs |
| `gateway-portal-web-server` (helm subchart) | `portal-controller` deploys web server per Portal CR |
| `CUSTOM_GROUP_CLAIM_KEY` + `ADMIN_GROUP_VALUES` env vars | Built-in: portal reads `groups` claim from ID token, `admin` group = portal admin |
| `PortalGroup` (claims-based API visibility) | `visibility.public` + OIDC login + subscription approval flow |
| `enterprise.gloo.solo.io/v1` AuthConfig | `extauth.solo.io/v1` AuthConfig |
| `RouteOption` with `extauth.configRef` | `EnterpriseKgatewayTrafficPolicy` with `entExtAuth.authConfigRef` |
| `headers.idTokenHeader: id_token` | `headers.idTokenHeader: id_token` (same — NOT `accessTokenHeader`) |
| `gatewayClassName: gloo-gateway` | `gatewayClassName: enterprise-kgateway` |
| ApiDoc via service annotations (auto-discovery) | ApiDoc CR with `servedBy` field (explicit) |
| K8s Gateway API v1.2.x | K8s Gateway API v1.5.1 (experimental channel) |

## CR-by-CR Comparison

All custom resources required for this portal setup (same apps, same OIDC provider, same functionality).

| Category | GGv1 (1.21.x) | kgateway 2.2.0 | Notes |
|---|---|---|---|
| **Gateway API** | | | |
| Gateway | 1 (`gloo-gateway`) | 1 (`enterprise-kgateway`) | Same structure, different gatewayClassName |
| HTTPRoute - portal frontend | 1 (portal-frontend-route, 2 rules: `/` + `/v1/login` + `/v1/logout`) | 2 (portal-frontend `/`, portal-login `/v1/login` + `/v1/logout`) | GGv1 combined both in one HTTPRoute with 2 rules; 2.2.0 splits them because TrafficPolicy targets a full HTTPRoute, not individual rules |
| HTTPRoute - portal backend | 0 (portal web server routed internally by gloo) | 1 (portal-backend `/v1/`) | In GGv1 the portal web server is co-located in the gloo-system namespace and the gateway routes to it implicitly. In 2.2.0 the portal backend is a separate service that needs its own HTTPRoute |
| HTTPRoute - API routes | 2 (tracks-route, petstore-route) | 2 (tracks-route, petstore-route) | Same |
| ReferenceGrant | 4 (tracks, users, pets, store) | 4 (tracks, users, pets, store) | Same — needed for cross-namespace backend refs |
| **Ext-Auth** | | | |
| AuthConfig (OIDC) | 1 `enterprise.gloo.solo.io/v1` | 1 `extauth.solo.io/v1` | Same spec, different apiVersion |
| AuthConfig (API key / portalAuth) | 0 (handled by helm config) | 1 (portal-api-auth) | GGv1 portal web server validates API keys internally; 2.2.0 uses ext-auth portalAuth filter |
| Secret (OIDC) | 1 `extauth.solo.io/oauth` | 1 `extauth.solo.io/oauth` | Same |
| RouteOption / TrafficPolicy (OIDC) | 1 RouteOption (`portal-cors`, combines CORS + extauth) | 2 EnterpriseKgatewayTrafficPolicy (`portal-oidc` + `portal-backend-oidc`) | GGv1 RouteOption applies to individual HTTPRoute rules via `ExtensionRef` filter. 2.2.0 TrafficPolicy targets entire HTTPRoutes via `targetRefs`, so login and backend need separate policies |
| RouteOption / TrafficPolicy (API auth) | 0 | 2 EnterpriseKgatewayTrafficPolicy (`tracks-auth` + `petstore-auth`) | GGv1 portal web server handled API key validation inline; 2.2.0 uses ext-auth + TrafficPolicy per API route |
| GatewayExtension (ext-auth timeout) | 0 (set in helm values: `global.extensions.extAuth.requestTimeout: 3s`) | 1 | GGv1 configures ext-auth timeout globally in helm values; 2.2.0 requires a GatewayExtension CR referenced by each TrafficPolicy |
| **Portal** | | | |
| Portal | 1 (auto-created by helm) | 1 (manual CR) | GGv1 portal web server is deployed by the `gateway-portal-web-server` helm subchart; 2.2.0 portal-controller creates the web server when it reconciles the Portal CR |
| PortalParameters | 0 | 1 | New in 2.2.0 — configures backend storage (in-memory or DB) |
| ApiProduct | 2 (created via helm / kubectl) | 2 (manual CR) | Same concept, different apiVersion (`portal.gloo.solo.io/v1` vs `portal.solo.io/v1alpha1`) |
| ApiDoc | 4 (auto-discovered from service annotations) | 4 (manual CR with `servedBy`) | GGv1 auto-discovers OpenAPI specs from service annotations; 2.2.0 requires explicit ApiDoc CRs with inline specs |
| PortalGroup | 2 (petstore-portal-group, tracks-portal-group) | 0 | GGv1 uses PortalGroup for claims-based API visibility; 2.2.0 uses `visibility.public: true` + subscription approval flow instead |
| **Workloads** | | | |
| Portal Frontend (Deployment + Service + SA) | 3 objects | 3 objects | Same React app, same env vars |
| Secret (TLS) | 1 | 1 | Same |

### Summary Count

| | GGv1 | kgateway 2.2.0 |
|---|---|---|
| Gateway API resources (Gateway, HTTPRoute, ReferenceGrant) | 8 | 10 |
| Ext-Auth resources (AuthConfig, RouteOption/TrafficPolicy, GatewayExtension, Secret) | 3 | 7 |
| Portal CRDs (Portal, PortalParameters, ApiProduct, ApiDoc, PortalGroup) | 9 | 8 |
| Workloads + Secrets (Deployment, Service, SA, TLS) | 4 | 4 |
| **Total CRs** | **24** | **29** |

The increase from 24 to 29 comes from 2.2.0 making ext-auth configuration explicit (TrafficPolicies + GatewayExtension) rather than bundled into helm values and RouteOption filters. The portal side is actually slightly fewer CRs because PortalGroups are replaced by the built-in subscription model.

## Okta Setup

Okta config carries over from GGv1:
- App: `gloo-portal` in Okta org `integrator-4829064`
- Authorization Server: `default` (issuer: `https://integrator-4829064.okta.com/oauth2/default`)
- `groups` claim configured as ID token mapper (regex `.*` to include all groups)
- Groups: `Everyone`, `admin`, `portal-admins`, `team-petstore`, `team-tracks`
- Admin users need `admin` in their `groups` claim to approve subscriptions
- Test users: `tracks1@solo.io` (regular user, can create teams)

## Deployed Resource Summary

| Resource | Count | Namespaces |
|---|---|---|
| Gateway | 1 | default |
| HTTPRoute | 5 | default (portal-backend, portal-frontend, portal-login, tracks-route, petstore-route) |
| GatewayExtension | 1 | kgateway-system (extauth-timeout) |
| EnterpriseKgatewayTrafficPolicy | 4 | default (portal-oidc, portal-backend-oidc, tracks-auth, petstore-auth) |
| AuthConfig | 2 | default (portal-oidc-okta, portal-api-auth) |
| Portal | 1 | default (demo-portal) |
| PortalParameters | 1 | default (portal-params, in-memory store) |
| ApiProduct | 2 | default (tracks-api-product, petstore-api-product) |
| ApiDoc | 4 manual + 2 stitched | tracks, users, pets, store + default (auto-stitched) |
| ReferenceGrant | 4 | tracks, users, pets, store |
| Secret | 2 | default (wildcard-servebeer-tls, portal-oidc-okta) |

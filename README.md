# Gateway API on Codiac — How-To Guide

Replace Codiac's default `ingress-nginx` cluster stack component with Kubernetes Gateway API, enabling HTTP ingress **and** TCP routing (e.g., SFTP on port 22) through a single unified gateway. This guide provisions an AKS cluster, installs [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/) as the Gateway API implementation, and stands up a web server and an SFTP server as Codiac SDLC assets.

---

## Why Gateway API over ingress-nginx?

| Concern | ingress-nginx | Gateway API |
|---|---|---|
| Protocol support | HTTP/HTTPS only | HTTP, HTTPS, TCP, TLS, UDP |
| Role model | Flat / annotation-driven | Role-oriented (infra / operator / dev) |
| TCP routing | Not native | TCPRoute (experimental channel) |
| Future standard | Deprecated roadmap | Official Kubernetes SIG project |

---

## Why NGINX Gateway Fabric?

- Purpose-built for the Gateway API spec (not retrofitted)
- Full conformance with Gateway API v1.5.1 (HTTP, GRPC, TLS, TCP, UDP)
- TCPRoute + UDPRoute support added in v2.4.0
- F5/NGINX-backed; clean architecture; straightforward Helm chart
- OCI Helm registry: `oci://ghcr.io/nginx/charts`

---

## Architecture Overview

```
Codiac Tenant: gateway-poc
│
├── k8sinfrx enterprise  (cluster infrastructure)
│   └── Cluster stack assets:
│       └── nginx-gateway-fabric  (Helm asset)
│           ├── onPreDeploy:  install Gateway API experimental CRDs
│           ├── helm values:  NGF controller config + GatewayClass
│           └── onPostDeploy: apply Gateway CR  (HTTP :80 + TCP :22 listeners)
│
└── main enterprise  (SDLC — built-in, no create needed)
    ├── webapp  (service asset: nginx:alpine)
    │   └── onPostDeploy: apply HTTPRoute → webapp service
    └── sftpd   (service asset: atmoz/sftp)
        └── onPostDeploy: apply TCPRoute  → sftpd service port 22
```

**Key design decisions:**
- The `Gateway` CR is cluster-level infrastructure → lives in `k8sinfrx`, deployed as `onPostDeploy` on the `nginx-gateway-fabric` Helm asset.
- `HTTPRoute` and `TCPRoute` are per-application resources → deployed via `onPostDeploy` on each SDLC asset, automatically removed on undeploy (LIFO).
- `hasIngress: false` on both SDLC assets — Codiac's existing Ingress CR creation is bypassed; routes are managed by the `onPostDeploy` mechanism instead.

---

## Requirements

This exercise was designed to meet the following requirements:

1. **Replace ingress-nginx** — Remove `ingress-nginx` from the default Codiac cluster stack and replace it with a Gateway API implementation that supports TCP-level routing.

2. **SFTP ingress via TCPRoute** — Expose an SFTP server (SSH, port 22) through the cluster's ingress layer using a `TCPRoute` resource. Standard `networking.k8s.io/v1 Ingress` objects only support HTTP/HTTPS; Gateway API's experimental channel is required.

3. **HTTP ingress via HTTPRoute** — Expose a web server through the same gateway using an `HTTPRoute`, demonstrating that HTTP and TCP traffic share a single unified entry point.

4. **Codiac-native implementation** — All k8s resources (CRDs, Gateway CR, HTTPRoute, TCPRoute) must be provisioned using Codiac configuration features (`onPredeploy`, `onPostDeploy`) rather than out-of-band `kubectl` commands, so that Codiac controls the full lifecycle (deploy and undeploy).

5. **No hardcoded namespaces** — Route manifests must be portable across cabinets. Use the `${cabinet.namespace}` context variable so the correct namespace is injected at deploy time.

6. **Per-asset route scoping** — HTTPRoute and TCPRoute are scoped to their respective SDLC assets (not the cluster infra layer), so each route is automatically removed when its asset is undeployed.

7. **Minimal, popular open-source containers** — Use `nginx:alpine` for the web server and `atmoz/sftp` for the SFTP server (35M+ Docker Hub pulls; single-env-var configuration).

---

## Prerequisites

- `cod` CLI installed and authenticated
- Azure subscription with Contributor access
- `az` CLI installed and logged in (`az login`)
- `kubectl` installed
- A Codiac tenant admin account

---

## Phase 0 — Tenant and CSP Setup

```bash
# Create a new Codiac tenant
cod auth register --tenantCode gateway-poc --tenantName "Gateway API POC"

# Log in under the new tenant
cod login

# Set up Azure CSP credentials (interactive)
cod csp setup --provider azure
```

---

## Phase 1 — Build the Custom Cluster Stack

> **Why do this before provisioning?**  
> Codiac's default cluster stack includes `ingress-nginx`. We build our own stack first,
> tag it as `default`, then bootstrap the cluster so it never installs ingress-nginx.

### 1a. Build the stack assets

```bash
# Create the NGINX Gateway Fabric Helm asset in the k8sinfrx enterprise
cod cluster stack capture

# Remove the ingress-nginx asset from the stack
cod asset obliterate -e k8sinfrx --silent -a ingress-nginx

# Register NGINX Gateway Fabric as a Helm asset in the infrx enterprise
# (The image field uses Helm registry syntax: helm|oci|<repo-name>)
cod asset create -e k8sinfrx \
  --name nginx-gateway-fabric \
  --type helm \
  --image "oci://ghcr.io/nginx/charts/nginx-gateway-fabric" \
  --port 80
```

### 1b. Install Gateway API CRDs before the Helm chart (onPreDeploy)

The experimental channel CRDs (required for TCPRoute) must exist before NGINX Gateway Fabric starts.

```bash
cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t onpredeploy \
  --setting "01-gateway-api-crds" \
  --value "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/experimental-install.yaml"
```

### 1c. Configure the Helm chart values

```bash
# Service type for the NGF LoadBalancer (gets an external IP from AKS)
cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t helm \
  --enterprise-scope \
  --setting "service.type" \
  --value "LoadBalancer"

# Name of the GatewayClass this controller manages
cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t helm \
  --enterprise-scope \
  --setting "gatewayClass.name" \
  --value "nginx"

# Expose port 22 on the LoadBalancer service for SFTP
cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t helm \
  --enterprise-scope \
  --setting "service.extraTcpPorts[0].name" \
  --value "sftp"

cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t helm \
  --enterprise-scope \
  --setting "service.extraTcpPorts[0].port" \
  --value "22"

cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t helm \
  --enterprise-scope \
  --setting "service.extraTcpPorts[0].targetPort" \
  --value "22"
```

### 1d. Create the Gateway CR (onPostDeploy)

The `Gateway` CR is applied after the Helm chart is installed. It creates the shared gateway with HTTP and TCP listeners. Scope this at the enterprise level so it applies to every cabinet.

```bash
# Write the Gateway CR manifest (see manifests/gateway.yaml)
# Then apply it as the onPostDeploy config:
cod config add -e k8sinfrx -a nginx-gateway-fabric \
  -t onpostdeploy \
  --setting "01-gateway-cr" \
  --value-stdin < manifests/gateway.yaml
```

### 1e. Tag the stack as default

```bash
# Capture a version of the current k8sinfrx stack
cod cluster stack capture

# Tag it as default so new clusters use it
cod cluster stack tag --tag default
```

---

## Phase 2 — Provision the AKS Cluster

```bash
cod cluster bootstrap my-gateway-cluster \
  --provider azure \
  --providerSubscription <your-azure-subscription-id> \
  --resourceGroup gateway-poc-rg \
  --location eastus \
  --nodeSpec Standard_D4s_v3 \
  --nodeQty 2 \
  --k8sVersion 1.30.0
```

> Codiac will provision the AKS cluster, install the Codiac agent, and install the tagged default cluster stack (which now includes NGINX Gateway Fabric instead of ingress-nginx).

---

## Phase 3 — SDLC Assets

> The `main` enterprise is built-in to every Codiac tenant — no `enterprise create` needed.

```bash
# Register the web server asset (nginx:alpine from Docker Hub)
cod asset create -e main \
  --name webapp \
  --type service \
  --image "nginx:alpine" \
  --port 80 \
  --no-ingress

# Register the SFTP server asset (atmoz/sftp from Docker Hub)
cod asset create -e main \
  --name sftpd \
  --type service \
  --image "atmoz/sftp" \
  --port 22 \
  --no-ingress
```

### 3a. Configure the SFTP server

`atmoz/sftp` is configured via environment variables.

```bash
# Set SFTP users: format is "user:password:uid"
cod config add -e main -a sftpd \
  -t env \
  --enterprise-scope \
  --setting "SFTP_USERS" \
  --value "demouser:changeme123:1001"
```

---

## Phase 4 — Wire Up Routes

### 4a. HTTPRoute for webapp

The `onPostDeploy` config on the `webapp` asset applies an HTTPRoute that attaches to the shared Gateway and forwards all HTTP traffic to the webapp service.

```bash
cod config add -e main -a webapp \
  -c dev-01 \
  -t onpostdeploy \
  --setting "01-http-route" \
  --value-stdin < manifests/webapp-httproute.yaml
```

### 4b. TCPRoute for sftpd

```bash
cod config add -e main -a sftpd \
  -c dev-01 \
  -t onpostdeploy \
  --setting "01-tcp-route" \
  --value-stdin < manifests/sftpd-tcproute.yaml
```

---

## Phase 5 — Create an Environment and Cabinet, Then Deploy

```bash
# Create an environment
cod env add --enterprise main --name dev

# Create a cabinet and attach it to the cluster
cod cabinet create --enterprise main --environment dev --name dev-01
cod cabinet cluster attach --enterprise main --cabinet dev-01 --cluster my-gateway-cluster

# Deploy
cod asset deploy -e main -a webapp -c dev-01 -u latest
cod asset deploy -e main -a sftpd -c dev-01 -u latest
```

---

## Phase 6 — Verification

```bash
# Get the external IP of the NGINX Gateway Fabric LoadBalancer
kubectl get svc -n k8sinfrx -l app.kubernetes.io/name=nginx-gateway-fabric

# Test HTTP
curl http://<EXTERNAL-IP>/

# Test SFTP
sftp -P 22 demouser@<EXTERNAL-IP>
```

---

## Cleanup

```bash
# Undeploy SDLC assets (routes are auto-deleted via onPostDeploy LIFO)
cod asset undeploy -e main -a webapp -c dev-01
cod asset undeploy -e main -a sftpd -c dev-01

# Destroy the cluster
cod cluster destroy my-gateway-cluster
```

---

## TODOs

- [ ] **hasIngress flag redesign**: The `hasIngress` flag on an Asset is currently tightly coupled to HTTP Ingress CR creation only. The Codiac relay (`k8s-ingress-manager.ts`) needs to be extended to support protocol-aware ingress — Gateway API HTTPRoute, TCPRoute, TLSRoute, etc. — rather than just creating a `networking.k8s.io/v1 Ingress` object. This is a Codiac platform engineering task.

---

## Implementation Notes

These notes capture platform-specific details that are easy to get wrong, especially if you're new to Codiac internals or Gateway API. See [README-codiac-docs-todos.md](./README-codiac-docs-todos.md) for full documentation gap writeups.

### onPredeploy / onPostDeploy config types

`onpredeploy` and `onpostdeploy` are not listed in the public Codiac docs, but they are the primary mechanism for applying freeform Kubernetes manifests as part of an asset's deploy/undeploy lifecycle.

- The `--value` is a URL, inline YAML, or inline JSON.
- Handlers within a type run in **alphabetical order** by `--setting` name — use numeric prefixes (`01-`, `02-`) to control sequencing.
- On undeploy, Codiac deletes `onpostdeploy` resources first (LIFO), then removes the chart/service, then deletes `onpredeploy` resources. This is why the Gateway CR and Route CRs are cleaned up automatically — no separate teardown script is needed.

### Namespace token substitution

Do **not** hardcode namespaces in handler YAML. The Codiac relay resolves `${dot.path}` tokens before applying the YAML. The key token:

```
${cabinet.namespace}   →   the k8s namespace for the deploying cabinet
```

This is implemented in `codiac-relay/src/utils/view-engine.ts` (`performTokenReplacements()`), which reads from `CabinetExpressionContext` and `AssetVersionExpressionContext`. Always use this token in `metadata.namespace` for Route CRs — this is what makes manifests portable across cabinets without sed substitution or per-cabinet copies.

### Gateway CR scope vs Route CR scope

- **Gateway CR** → `k8sinfrx` / `onPostDeploy` on `nginx-gateway-fabric`: The gateway is cluster infrastructure. One gateway serves all cabinets. Namespace: `nginx-gateway` (the NGF controller namespace).
- **HTTPRoute / TCPRoute** → SDLC asset `onPostDeploy`, scoped to a specific cabinet (`-c <cabinet>`): Routes are application-level. Each asset owns its route, so undeploy cleans it up automatically.

### Gateway listeners and cross-namespace routing

The Gateway CR has `allowedRoutes.namespaces.from: All` on each listener. This lets Route CRs in any cabinet namespace attach to the gateway without a `ReferenceGrant`. If you tighten this to `Same` or `Selector`, you will need `ReferenceGrant` objects in the gateway's namespace for each cabinet that needs to attach.

### Why `--no-ingress` on SDLC assets

Codiac normally creates a `networking.k8s.io/v1 Ingress` object when an asset has `hasIngress: true`. That Ingress object is for ingress-nginx (HTTP only) and conflicts with our Gateway API approach. Pass `--no-ingress` (sets `hasIngress: false`) to skip Ingress CR creation entirely — the `onPostDeploy` route configs handle ingress instead.

### NGINX Gateway Fabric port 22 on the LoadBalancer

The NGF Helm chart exposes ports through its `Service` spec. Port 22 is not included by default. The `service.extraTcpPorts` Helm values (set via `cod config add -t helm`) add port 22 to the LoadBalancer service, which is what gives the external IP a port-22 endpoint for SFTP clients.

### atmoz/sftp configuration

`atmoz/sftp` reads user accounts from the `SFTP_USERS` environment variable. Format: `user:password:uid`. Example: `demouser:changeme123:1001`. Multiple users are separated by spaces. The container chroots each user to `/home/<user>/upload` by default.

---

## Sources

- [Kubernetes Gateway API — Official Docs](https://gateway-api.sigs.k8s.io/)
- [Gateway API Getting Started](https://gateway-api.sigs.k8s.io/guides/getting-started/)
- [Gateway API Implementations List](https://gateway-api.sigs.k8s.io/implementations/)
- [NGINX Gateway Fabric Docs](https://docs.nginx.com/nginx-gateway-fabric/)
- [NGINX Gateway Fabric GitHub](https://github.com/nginx/nginx-gateway-fabric)
- [NGINX Gateway Fabric 2.4.0 Release Notes — TCPRoute/UDPRoute](https://blog.nginx.org/blog/whats-new-in-f5-nginx-gateway-fabric-2-4-0)
- [Gateway API TCP Routing Guide](https://gateway-api.sigs.k8s.io/guides/tcp/)
- [Envoy Gateway TCP Routing](https://gateway.envoyproxy.io/v1.4/tasks/traffic/tcp-routing/)
- [Contour Gateway API Support](https://projectcontour.io/docs/1.32/config/gateway-api/)
- [atmoz/sftp Docker Hub](https://hub.docker.com/r/atmoz/sftp)
- [Codiac Documentation](https://docs.codiac.io/)

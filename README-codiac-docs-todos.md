# Codiac Docs — Gaps & Todos

This file tracks shortcomings discovered in the public Codiac documentation (docs.codiac.io) during the gateway-api exercise, plus what we eventually learned. It is intended to feed back into the official docs.

---

## TODO-001: onPredeploy / onPostDeploy config types not documented

**Discovered:** During the gateway-api exercise when researching how to apply freeform Kubernetes manifests (CRDs, Gateway, HTTPRoute, TCPRoute) as part of an asset deployment.

**Gap:** The public docs describe config types like `helm`, `env`, `footprint`, `file`, and `annotation`, but do not mention `onpredeploy` or `onpostdeploy` as config types available to asset authors.

**What we learned (from `codiac-relay` source):**

`onpredeploy` and `onpostdeploy` are special config types settable via:

```bash
cod config add -e <enterprise> -a <asset> -t onpredeploy --setting "<handler-name>" --value "<yaml|json|url>"
cod config add -e <enterprise> -a <asset> -t onpostdeploy --setting "<handler-name>" --value "<yaml|json|url>"
```

The `--value` may be:
- A URL (`https://...`) → `kubectl apply -f <url>` is run
- A Kubernetes YAML block (single or multi-document `---`) → `kubectl apply -f -` is run  
- A Kubernetes JSON object → parsed and applied

Handlers within each type are executed **in alphabetical order** by the `--setting` name. To control order, prefix names with a two-digit sequence (e.g., `01-gateway-api-crds`, `02-gateway-cr`).

**Lifecycle (LIFO on undeploy):**

| Deploy phase | Handler |
|---|---|
| Pre-deploy | `onpredeploy` handlers run first, then chart/service |
| Post-deploy | Chart/service deploys, then `onpostdeploy` handlers |
| Pre-undeploy | `onpostdeploy` handlers are **deleted** first |
| Post-undeploy | Chart/service uninstalls, then `onpredeploy` handlers are **deleted** |

This LIFO pattern ensures that resources created in `onpostdeploy` (like a Gateway CR or Route CRs) are cleaned up before the chart that manages them is removed.

**Source files:**
- `codiac-relay/src/ops/k8s/k8s-helm-deployer.ts` — `deploySingleAsset()`
- `codiac-relay/src/ops/k8s/k8s-service-deployer.private.ts` — `deploySingleAsset()` and `destroy()`
- `codiac-relay/src/ops/k8s/client/k8s-applicator.ts` — `invokeK8sHandlers()`, `invokeK8sDeleteHandlers()`

---

## TODO-002: k8spatch config type not documented

**Discovered:** During the gateway-api exercise when researching raw k8s object customization options.

**Gap:** The `k8spatch` config type (also known as `k8spatches`) is not mentioned in public docs. It allows asset authors to apply JSON Patch operations directly to the k8s `Deployment`, `Service`, `Ingress`, and `Pod` objects that Codiac generates.

**What we learned (from `codiac-relay` source):**

```bash
cod config add -e <enterprise> -a <asset> -t k8spatch \
  --setting "deployment" \
  --value '[{"op": "add", "path": "/spec/template/spec/hostNetwork", "value": true}]'
```

The value is an array of [JSON Patch (RFC 6902)](https://jsonpatch.com/) operations. The `path` field uses the standard JSON Pointer syntax relative to the root of the target k8s object.

Supported patch targets: `deployment`, `service`, `ingress`, `pod`.

**Source files:**
- `codiac-relay/src/ops/k8s/k8s-service-deployer.private.ts` — `applyK8sPatches()`, `applyK8sPatches_inMemory()`

---

## TODO-003: Cluster stack management — removing default ingress-nginx not documented

**Discovered:** When trying to replace ingress-nginx with NGINX Gateway Fabric in the cluster stack.

**Gap:** The public docs don't explain that the default Codiac cluster stack includes `ingress-nginx` as an explicit `k8sinfrx` asset, nor do they describe the workflow for replacing it before provisioning a cluster.

**What we learned:**

Two paths depending on whether a cluster has already been provisioned:

**Before provisioning (preferred):**

```bash
# Option A: Capture the built-in stack, then obliterate ingress-nginx
cod cluster stack capture
cod asset obliterate -e k8sinfrx -a ingress-nginx
# Add your replacement asset(s), then:
cod cluster stack capture        # snapshot the modified stack
cod cluster stack tag --tag default   # mark it as the new default
# Then bootstrap the cluster — it will use your custom stack

# Option B: Build a custom stack from scratch
cod asset create -e k8sinfrx --name <my-ingress> ...
# add configs, then capture + tag as default
```

**After provisioning (remediation):**

```bash
# 1. Remove the running ingress-nginx instance from the cluster
cod cluster uninstall <cluster-name> -a ingress-nginx

# 2. Remove the ingress-nginx asset record from the k8sinfrx enterprise
cod asset obliterate -e k8sinfrx -a ingress-nginx

# 3. Add your replacement asset and re-install
```

---

## TODO-004: onPostDeploy namespace context — using cabinet namespace in handler YAML

**Discovered:** When designing HTTPRoute and TCPRoute placement for SDLC assets.

**Gap:** The public docs don't explain how to reference the cabinet's namespace inside `onpredeploy`/`onpostdeploy` handler YAML. Without this, authors either hardcode a namespace (breaks multi-cabinet portability) or omit it (resource lands in the default kubeconfig namespace, which is wrong).

**What we learned:**

The Codiac relay performs token substitution on handler YAML values before applying them. The token syntax is `${dot.path}`, referencing the `CabinetExpressionContext` and `AssetVersionExpressionContext` objects assembled by `ExpressionContextMapper`. The replacement is performed in `codiac-relay/src/utils/view-engine.ts` (`performTokenReplacements()`).

Use `${cabinet.namespace}` in handler YAML to inject the cabinet's namespace at deploy time:

```yaml
metadata:
  name: my-route
  namespace: ${cabinet.namespace}
```

This is the correct, portable approach — no shell substitution or per-cabinet manifest copies needed. The `namespace` config type (`cod config add -t namespace`) can also be used to set the deployment namespace for an asset, which feeds into the same context object.

**Other useful tokens (same syntax):**
- `${cabinet.name}` — cabinet code
- `${cabinet.namespace}` — fully-qualified k8s namespace for this cabinet
- `${asset.name}` — asset code
- `${asset.version}` — deployed version tag

**Docs recommended:** A dedicated section in the onPredeploy/onPostDeploy documentation listing available context tokens, with a cross-namespace routing example showing `${cabinet.namespace}`.

**Source files:**
- `codiac-relay/src/utils/view-engine.ts` — `performTokenReplacements()`
- `codiac-relay/src/ops/expression-context-mapper.ts` — `CabinetExpressionContext`, `AssetVersionExpressionContext`

---

## TODO-006: Expression context schema not documented — available tokens for onPredeploy/onPostDeploy values

**Discovered:** When trying to use `${cabinet.namespace}` in Route CR manifests and realizing there is no reference listing what properties are available.

**Gap:** The `onpredeploy` and `onpostdeploy` handler values support `${dot.path}` token substitution against a context object assembled at deploy time. The context types (`CabinetExpressionContext`, `AssetVersionExpressionContext`) and the full set of available tokens are not documented anywhere in the public docs.

**What we learned (from `codiac-relay` source):**

The context is assembled by `ExpressionContextMapper` and passed into `performTokenReplacements()` in `codiac-relay/src/utils/view-engine.ts`. The token syntax is `${<property>.<subproperty>}`.

Known available tokens (verify against `ExpressionContextMapper` for the authoritative list):

| Token | Resolves to |
|---|---|
| `${cabinet.namespace}` | The k8s namespace for the deploying cabinet |
| `${cabinet.name}` | The cabinet code |
| `${asset.name}` | The asset code |
| `${asset.version}` | The deployed version tag |

Example usage in a manifest:

```yaml
metadata:
  name: my-route
  namespace: ${cabinet.namespace}
spec:
  parentRefs:
  - name: codiac-gateway
    namespace: nginx-gateway
  backendRefs:
  - name: ${asset.name}
    port: 80
```

Example usage in a URL-style config value (e.g., a health-check endpoint):

```
https://my-service.${cabinet.name}.oncodiac.io/health
```

**Docs recommended:**
- A reference table of all properties on `CabinetExpressionContext` and `AssetVersionExpressionContext` with descriptions and example values
- A note in the `onpredeploy`/`onpostdeploy` docs section explaining that handler values are template-rendered before `kubectl apply` is called
- At least one worked example showing `${cabinet.namespace}` in a Route CR manifest

**Source files:**
- `codiac-relay/src/utils/view-engine.ts` — `performTokenReplacements()`
- `codiac-relay/src/ops/expression-context-mapper.ts` — `CabinetExpressionContext`, `AssetVersionExpressionContext`

---

## TODO-005: docs.codiac.io agent/crawler accessibility — diagnosis and status

**Discovered:** When attempting to fetch documentation content to assist with this exercise.

**Corrected diagnosis:** The original assumption (blank SPA) was partially wrong. Docusaurus 3 already SSR's every page to static HTML during `docusaurus build` — a properly built and deployed site returns content-rich HTML to any HTTP client, including AI crawlers. The issue encountered was primarily **URL discovery**: the docs are rooted at `/v1/` (`routeBasePath: 'v1'` in `docusaurus.config.js`), not `/` or `/docs/`, so fetching the root returned a minimal landing page and attempts at `/docs/...` paths returned 404s.

**Status of agent-friendliness infrastructure (already in place):**

| Mechanism | Status |
|---|---|
| SSR / static HTML | ✅ Built in to `docusaurus build` |
| `sitemap.xml` | ✅ Generated by `@docusaurus/preset-classic`; referenced in `robots.txt` |
| `robots.txt` | ✅ Explicitly allows all major AI crawlers (GPTBot, ClaudeBot, anthropic-ai, PerplexityBot, etc.) |
| `llms.txt` | ✅ Present at `static/llms.txt`; referenced in `robots.txt` |
| Vercel deployment | ✅ `buildCommand` and `outputDirectory` now explicit in `vercel.json` |

**Remaining gap:** The `llms.txt` covers the main sections but does not list every doc page individually (e.g., `config-on-deploy-guide`, `cli-manage-cluster-stacks`, `cli-manage-configurations`). An AI agent following only `llms.txt` will miss pages not enumerated there. The sitemap covers the rest, but not all agents follow sitemaps.

**Suggested improvement:** Periodically audit `llms.txt` against the actual doc file list to ensure high-value pages are explicitly linked, especially as new features are documented.

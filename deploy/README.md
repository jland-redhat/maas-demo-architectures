# Deploying demo workloads (models + groups + entitlements)

This repo installs **simulated** inference workloads (same pattern as [upstream samples](https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/models/simulator)): five `LLMInferenceService` objects using `ghcr.io/llm-d/llm-d-inference-sim`, plus matching **`MaaSModelRef`**, OpenShift **`Group`**, and your chosen demo’s **`MaaSSubscription` / `MaaSAuthPolicy`**.

**Prerequisite:** [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) is installed on OpenShift (Gateway `maas-default-gateway` in `openshift-ingress`, KServe, MaaS operator, etc.). For lab infra (Kuadrant CR, gateway TLS, Authorino TLS, PostgreSQL / **`maas-db-config`**), see [infra/README.md](../infra/README.md) (`./infra/scripts/install-infra.sh`).

## One command (default: Demo 01 entitlements)

From the **repository root** (paths in `kustomization.yaml` stay inside the repo — no extra flags):

```bash
oc apply -k .
```

That applies `deploy/base` (namespaces, groups, five simulators, five `MaaSModelRef`) plus `demos/01-one-to-one/manifests/maas-entitlements.yaml`.

To switch the default bundle, edit the root `kustomization.yaml` and change the second `resources` entry to another demo path.

## One command per overlay (any demo)

`oc kustomize` blocks references **outside** the overlay directory unless you relax the loader. Use **`LoadRestrictionsNone`** and pipe to apply:

```bash
oc kustomize --load-restrictor LoadRestrictionsNone deploy/overlays/demo02 | oc apply -f -
```

Replace `demo02` with `demo01` … `demo09` or use `models-only` (no `MaaS*` entitlements — only base). Demo **09** adds the llm-d EPP simulator (`demo09-epp-sim`); see [demos/09-llm-d-epp](../demos/09-llm-d-epp/).

**Models-only** (no subscriptions/policies):

```bash
oc kustomize deploy/overlays/models-only | oc apply -f -
```

(`models-only` does not need `LoadRestrictionsNone` because all resources live under that directory.)

## What gets installed

| Layer | Location |
|--------|----------|
| Namespaces `llm`, `models-as-a-service`, `ai-tenants` | `deploy/base/namespaces.yaml` |
| OpenShift `Group` objects | `deploy/base/groups.yaml` (keep in sync with `shared/identity/common-openshift-groups.yaml`) |
| Five `LLMInferenceService` simulators | `deploy/base/inference/simulators.yaml` |
| Five `MaaSModelRef` (on-cluster) | `deploy/base/maas-modelrefs/modelrefs.yaml` |
| Entitlements (+ Demo 08 external model) | `demos/<demo>/manifests/` |

## Demo token limits (`tokenRateLimits`)

Manifests use **small numbers** so live demos stay easy: roughly **50–2000 tokens per minute** per model (same `1m` window everywhere). Tight caps (**50**) mark “expensive” or lowest-tier routes; **2000** is the lab ceiling. Raise limits in your fork for production-like load tests.

## Lab users and passwords

Groups reference users **`alice`**, **`bob`**, **`chloe`**, **`dana`**. They must exist in your IdP. **Who is in which group** (and what each demo means for them) is documented per pattern under [demos/](../demos/README.md), with a **full** membership matrix in [demos/README.md — Full lab identity](../demos/README.md#full-lab-identity-openshift-groups). For an **HTPasswd** IdP, generate a file with [shared/identity/htpasswd-sample-users.sh](../shared/identity/htpasswd-sample-users.sh), create the OAuth secret, and add the IdP to the cluster (see OpenShift **Identity Providers** documentation).

## Log in as a specific user (real credentials)

```bash
oc login --token=<your-token>  # or user/password against API URL
# HTPasswd example:
oc login -u alice -p alicepass https://api.<cluster>:6443
```

## Can I get a token for another user?

**Not as an administrator impersonating them**, in the sense of minting that person’s **OAuth access token** without their participation. OpenShift does not offer “assume user and receive their long‑lived bearer token” the way some cloud IAM systems do—that would break accountability.

What you can do instead:

| Need | Approach |
|------|----------|
| **A real user token** for testing | Have that user **`oc login`** (password, web OAuth, or `oc login --token` after they obtain a token from the console). |
| **Short‑lived proof of identity** | User runs **`oc whoami -t`** after logging in; they hand you the token only in a controlled lab (tokens are secrets). |
| **API calls as another user without their password** | **`--as` / `--as-group`** impersonation (cluster admins); not a token, but each request is evaluated as that user. |
| **Non‑human callers** | **`ServiceAccount`** tokens: `oc create token -n <ns> <sa-name>` (Kubernetes 1.24+ style) or bound tokens per cluster docs. |

So: **you cannot safely “fetch Alice’s token” without Alice authenticating** (or without a pre‑provisioned credential you are allowed to use). Use **`oc login` as Alice** in a lab, or **impersonation** for RBAC checks.

## Impersonate a user for quick API / RBAC checks (cluster admins)

If your kubeconfig user may **impersonate** (typically **cluster-admin**), you can run `oc` / API calls **as** another user and **as** their groups (JWT-style groups for authorization checks):

```bash
# Resolve effective identity (example: alice in the Granite line-item group)
oc whoami --as=alice --as-group=maas-demo-line-granite --as-group=system:authenticated

# Example: list namespaced resources visible under that identity
oc get maasmodelref -n llm --as=alice --as-group=maas-demo-line-granite --as-group=system:authenticated
```

Repeat `--as-group` for every group the user should belong to for that request. This does **not** create a full OAuth session or MaaS API key; it is useful for **kubectl-level** RBAC debugging. MaaS gateway auth still follows your real IdP and API key flows.

## Verify workloads

```bash
oc get llminferenceservice -n llm
oc get maasmodelref -n llm
oc get maassubscription,maasauthpolicy -n models-as-a-service
```

Wait until `MaaSModelRef` **phase** is `Ready` and pods in `llm` are running before calling the MaaS API.

### Generate traffic (observability)

Hit models through MaaS gateways (BBR). Discovers IDs from `/maas-api/v1/models` and mints a key per gateway when needed:

```bash
./scripts/generate-traffic.sh                         # maas + partner-maas
./scripts/generate-traffic.sh --requests 10
./scripts/generate-traffic.sh --gateways maas --models granite,sim-chat
./scripts/generate-traffic.sh --direct                # optional: in-cluster workload Services
```

## MaaS platform notes (v0.1.2+ / RHOAI · ODH 3.5+)

| Topic | What to expect |
|-------|----------------|
| **CRD version** | `maas.opendatahub.io/v1alpha1` (`ExternalModel` same group; optional `inference.opendatahub.io` ExternalProvider path in newer IPP flows) |
| **Quota** | Inline **`tokenRateLimits`** on each `modelRefs[]` entry in `MaaSSubscription` |
| **Tenant namespace** | Apply subscriptions/policies in a namespace with **`MaasTenantConfig`** (default: `models-as-a-service`). Do **not** put them in `llm`. |
| **Platform tenancy** | **`AITenant`** in `ai-tenants`; additional tenants → `ai-tenant-{name}` + dedicated Gateway |
| **API keys** | `POST ${MAAS_API_URL}/maas-api/v1/api-keys` with OpenShift bearer token; optional **`subscription`** field binds the key to one `MaaSSubscription` |
| **Gateway auth** | Controller manages **`AuthPolicy/maas-gateway-auth`** in `openshift-ingress`; per-model gateway policies in `llm` are not used |
| **Inference (BBR)** | Prefer `POST ${MAAS_API_URL}/v1/chat/completions` with `model` in the body (IPP). Path-based `${MODEL_URL}/v1/chat/completions` still works. |
| **External models** | `ExternalModel` + `MaaSModelRef` in `llm`; provider Secret labeled `inference.llm-d.ai/ipp-managed=true` — see [Demo 08](../demos/08-maas-35-features/) |
| **Overlapping subscriptions** | Demo 02 owners on Gold+Silver+Bronze — mint keys with explicit **`subscription`** or pass **`X-MaaS-Subscription`** on inference when needed |

MaaS API URL pattern: `https://maas.${CLUSTER_DOMAIN}/maas-api/v1/...` (see upstream [Inference](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/user-guide/inference.md) guide).

**Agent demo:** overlay **`demo07`** + [demos/07-openclaw-agent/README.md](../demos/07-openclaw-agent/README.md) wires OpenClaw to MaaS with a **bob** API key (prefer BBR `base_url`).

**3.5 feature demo:** [demos/08-maas-35-features/](../demos/08-maas-35-features/) — default + partner tenants via [apply-partner-tenant.sh](../demos/08-maas-35-features/scripts/apply-partner-tenant.sh), plus **External OIDC** tenant via [apply-oidc-tenant.sh](../demos/08-maas-35-features/scripts/apply-oidc-tenant.sh) (calls upstream Keycloak samples from a `MAAS_REPO` checkout).

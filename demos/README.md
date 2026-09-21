# Demos (Open Data Hub MaaS)

Each folder is a **governance pattern** for [opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) using real **`maas.opendatahub.io/v1alpha1`** resources. Read [Access and Quota Overview](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/subscription-overview.md) first: **`MaaSAuthPolicy`** = access, **`MaaSSubscription`** = quota; both must allow the request.

**The cast (lab users):** each folder below ties the YAML to **`alice`**, **`bob`**, **`chloe`**, and **`dana`**. Every demo README includes **OpenShift `Group` membership** for that pattern (and a **“Who’s who”** for what they can invoke). A **full** four-user matrix (all groups in one place) is in [Full lab identity](#full-lab-identity-openshift-groups) below.

**Prerequisite:** deploy upstream MaaS. To install **simulators + model refs + groups + entitlements** in one step, use Kustomize ([deploy/README.md](../deploy/README.md)) instead of hand-applying each demo manifest.

## Why pick which pattern?

| Folder | Pattern | Why you would use it |
|--------|---------|----------------------|
| [01-one-to-one](01-one-to-one/) | **Paired** subscription + policy | **Simplest starting point:** each entitlement is one **group** with **one** subscription and **one** policy (same group in both). Easy audits; can scale to **many models per pair** (bundle). Assumes **one primary group per user** in the story for clarity. |
| [02-tier-based](02-tier-based/) | Tier catalog + team slices | You sell **Gold/Silver/Bronze**-style products: each tier lists **all** models; **policies** still limit which **teams** see which models. Same org can hold **multiple** tier subscriptions (priority / API key choice). |
| [03-org-catalog](03-org-catalog/) | Single org subscription | **One** central procurement line for the whole platform; **policies** carve access by team (plus admins). Good when billing is centralized but RBAC stays granular. |
| [04-model-sku](04-model-sku/) | Many SKUs, one team | **FinOps** tracks **per-model** purchases; **one** group owns **several** single-model subscriptions with different **`priority`**. |
| [05-quota-overlay](05-quota-overlay/) | Quota-first | You need **uneven** per-model caps (expensive models throttled) **and** team policies on top of one shared subscription. |
| [06-abac-environment](06-abac-environment/) | Metering metadata | You need **labels** on subscriptions and **chargeback** metadata on policies for billing telemetry, not just RBAC. |
| [07-openclaw-agent](07-openclaw-agent/) | Agent via MaaS | **OpenClaw** (or any OpenAI-compatible agent) calls **Llama** through the MaaS gateway with a user-minted **`sk-oai-*`** key bound to one subscription. |
| [08-maas-35-features](08-maas-35-features/) | RHOAI / ODH **3.5** gateway | **BBR**, **ExternalModel**, **three tenants** (default + partner + **OIDC/Keycloak** via upstream samples). |
| [09-llm-d-epp](09-llm-d-epp/) | llm-d **EPP** smoke | Multi-replica simulator with **`router.scheduler`** → `InferencePool` + Endpoint Picker in path |

| Folder | What you apply (summary) |
|--------|--------------------------|
| [01-one-to-one](01-one-to-one/) | Five subscription+policy **pairs**; **unique** group per pair (one model per pair in YAML; bundles possible) |
| [02-tier-based](02-tier-based/) | Gold / Silver / Bronze subscriptions (each lists **all five** models); team policies slice models |
| [03-org-catalog](03-org-catalog/) | One org subscription (**five** models); **four** policies (teams + admins) |
| [04-model-sku](04-model-sku/) | **Five** SKU subscriptions for one group; priorities **35–31**; five policies |
| [05-quota-overlay](05-quota-overlay/) | One subscription (**five** models, uneven limits); **three** team policies |
| [06-abac-environment](06-abac-environment/) | One subscription + **`tokenMetadata`**; **three** policies with **`meteringMetadata`** |
| [07-openclaw-agent](07-openclaw-agent/) | One subscription + policy for **Llama**; wire [openclaw-infra](https://github.com/redhat-et/openclaw-infra) to MaaS |
| [08-maas-35-features](08-maas-35-features/) | Default (Granite + llm-katan sims + `sim-stream`) + partner (Mistral+Llama) + **OIDC** (Qwen+GPT-OSS / Keycloak tenant-a) |
| [09-llm-d-epp](09-llm-d-epp/) | `demo09-epp-sim` LLMIS (**3** replicas + scheduler) + subscription/policy; `validate-epp.sh` |

Shared: [shared/models/catalog.yaml](../shared/models/catalog.yaml), [shared/identity/](../shared/identity/).

Each demo’s **`manifests/required-groups.yaml`** applies only the **OpenShift `Group`** objects that demo’s `MaaSSubscription` / `MaaSAuthPolicy` reference (subset of [common-openshift-groups.yaml](../shared/identity/common-openshift-groups.yaml)). Full installs via [deploy/README.md](../deploy/README.md) still use **`deploy/base/groups.yaml`** (all demo groups at once).

## MaaS version alignment (v0.1.2+ / RHOAI · ODH 3.5+)

These demos target **`maas.opendatahub.io/v1alpha1`** as shipped with **MaaS v0.1.2** (RHOAI / ODH **3.5**). YAML in this repo already matches the subscription model:

- **Inline `tokenRateLimits`** on every `MaaSSubscription.spec.modelRefs[]` entry (no `tokenRateLimitRef`)
- **Entitlements in a tenant namespace** that has **`MaasTenantConfig/default-tenant`** (default: `models-as-a-service`; legacy `Tenant` is migrated automatically)
- **Programmatic access** via **`sk-oai-*`** API keys; each key is **bound to one subscription** at mint time (`subscription` field on `POST /v1/api-keys`)
- **`spec.priority`** on subscriptions — used for default subscription selection when minting keys and for tie-breaking (see [Demo 02](02-tier-based/) for overlapping tiers)
- **Body-based routing** — preferred inference URL is `POST /v1/chat/completions` with `model` in the JSON body (IPP required); path-based URLs remain supported
- **External backends** via **`ExternalModel`** + `MaaSModelRef` (`kind: ExternalModel`) — see [Demo 08](08-maas-35-features/)
- **Singleton gateway AuthPolicy** — controller reconciles **`AuthPolicy/maas-gateway-auth`** in `openshift-ingress` (not per-model policies in `llm`)

**DSC note (3.5):** MaaS is under **`aigateway.modelsAsAService`** (KServe is no longer a prerequisite for MaaS). See upstream [Upgrade to 3.5](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/migration/upgrade-to-3.5.md).

For authoritative CRD and release notes, see [opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/).

### Preferred inference (body-based routing)

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MAAS_API_URL="https://maas.${CLUSTER_DOMAIN}"
# MODEL_ID from GET ${MAAS_API_URL}/maas-api/v1/models → .data[].id

curl -sS \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":64}" \
  "${MAAS_API_URL}/v1/chat/completions"
```

Path-based (still valid): `${MODEL_URL}/v1/chat/completions` where `MODEL_URL` is `.data[].url` from model discovery.

## Presenter access (`maas-admin`)

OpenShift group **`maas-admin`** is listed on **every** `MaaSSubscription` owner and `MaaSAuthPolicy` subjects in this repo (including Demo 08 partner + OIDC tenants). Lab installs default it to common cluster-admin usernames (`htpasswd-cluster-admin-user`, `kubeadmin`, `cluster-admin`, `admin`). Add yourself if needed:

```bash
oc adm groups add-users maas-admin $(oc whoami)
# or edit users: in shared/identity/common-openshift-groups.yaml / deploy/base/groups.yaml
```

Then mint keys / call models without joining each persona group. On Demo 02 (overlapping tiers), pass `"subscription": "demo02-tier-…"` when creating an API key so the binding is unambiguous.

## Full lab identity (OpenShift groups)

Use this when you load **`deploy/base/groups.yaml`** (or [common-openshift-groups.yaml](../shared/identity/common-openshift-groups.yaml)) so every demo’s groups exist at once. A user may belong to **several** groups; **team** groups (`maas-demo-research`, …) and **line-item** groups (`maas-demo-line-*`) from Demo 01 can coexist on the same user.

| User | OpenShift `Group` membership |
|------|------------------------------|
| **(presenter)** | **`maas-admin`** (defaults: `htpasswd-cluster-admin-user`, `kubeadmin`, `cluster-admin`, `admin`) |
| **alice** | `maas-demo-research`, `maas-demo-apps`, `maas-demo-org`, `maas-demo-line-granite`, `maas-demo-line-gpt` |
| **bob** | `maas-demo-apps`, `maas-demo-org`, `maas-demo-line-llama` |
| **chloe** | `maas-demo-restricted`, `maas-demo-org`, `maas-demo-line-mistral` |
| **dana** | `maas-demo-admins`, `maas-demo-line-qwen`, `maas-demo-line-gpt` |

**Personas (cross-demo)**

- **alice** — Research and apps in team-based demos; Demo 08 **default** tenant hybrid catalog (Granite + llm-katan external sims); in Demo 01, **Granite** and **GPT-OSS** line items (two groups on purpose).
- **bob** — Apps team; Demo 01 **Llama** line item; Demo 07 OpenClaw agent; Demo 08 **partner** tenant (Mistral + Llama).
- **chloe** — Restricted team; Demo 01 **Mistral** line item.
- **dana** — Only user in **`maas-demo-admins`** for full-catalog admin policy; Demo 01 **Qwen** line item; shares **GPT-OSS** line item with alice.

## Lab hygiene

Demo manifests use distinct resource names (`demo01-*`, `demo02-*`, …). If you reuse the same cluster, **delete** a demo’s `MaaSSubscription` and `MaaSAuthPolicy` objects before applying another pattern that reuses the same `MaaSModelRef` names and groups, so quota and controller state stay predictable. Demo 08 also adds llm-katan `ExternalModel` sims (`sim-chat`, `sim-chat-2`, `sim-messages`) and paced SSE `sim-stream` in `llm`, partner resources in `llm-partner` / `ai-tenant-partner`, and Gateway `partner` — tear those down (or `oc delete aitenant partner -n ai-tenants`) when finished.

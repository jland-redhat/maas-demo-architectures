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

| Folder | What you apply (summary) |
|--------|--------------------------|
| [01-one-to-one](01-one-to-one/) | Five subscription+policy **pairs**; **unique** group per pair (one model per pair in YAML; bundles possible) |
| [02-tier-based](02-tier-based/) | Gold / Silver / Bronze subscriptions (each lists **all five** models); team policies slice models |
| [03-org-catalog](03-org-catalog/) | One org subscription (**five** models); **four** policies (teams + admins) |
| [04-model-sku](04-model-sku/) | **Five** SKU subscriptions for one group; priorities **35–31**; five policies |
| [05-quota-overlay](05-quota-overlay/) | One subscription (**five** models, uneven limits); **three** team policies |
| [06-abac-environment](06-abac-environment/) | One subscription + **`tokenMetadata`**; **three** policies with **`meteringMetadata`** |

Shared: [shared/models/catalog.yaml](../shared/models/catalog.yaml), [shared/identity/](../shared/identity/).

Each demo’s **`manifests/required-groups.yaml`** applies only the **OpenShift `Group`** objects that demo’s `MaaSSubscription` / `MaaSAuthPolicy` reference (subset of [common-openshift-groups.yaml](../shared/identity/common-openshift-groups.yaml)). Full installs via [deploy/README.md](../deploy/README.md) still use **`deploy/base/groups.yaml`** (all demo groups at once).

## Full lab identity (OpenShift groups)

Use this when you load **`deploy/base/groups.yaml`** (or [common-openshift-groups.yaml](../shared/identity/common-openshift-groups.yaml)) so every demo’s groups exist at once. A user may belong to **several** groups; **team** groups (`maas-demo-research`, …) and **line-item** groups (`maas-demo-line-*`) from Demo 01 can coexist on the same user.

| User | OpenShift `Group` membership |
|------|------------------------------|
| **alice** | `maas-demo-research`, `maas-demo-apps`, `maas-demo-org`, `maas-demo-line-granite`, `maas-demo-line-gpt` |
| **bob** | `maas-demo-apps`, `maas-demo-org`, `maas-demo-line-llama` |
| **chloe** | `maas-demo-restricted`, `maas-demo-org`, `maas-demo-line-mistral` |
| **dana** | `maas-demo-admins`, `maas-demo-line-qwen`, `maas-demo-line-gpt` |

**Personas (cross-demo)**

- **alice** — Research and apps in team-based demos; in Demo 01, **Granite** and **GPT-OSS** line items (two groups on purpose).
- **bob** — Apps team; Demo 01 **Llama** line item.
- **chloe** — Restricted team; Demo 01 **Mistral** line item.
- **dana** — Only user in **`maas-demo-admins`** for full-catalog admin policy; Demo 01 **Qwen** line item; shares **GPT-OSS** line item with alice.

## Lab hygiene

Demo manifests use distinct resource names (`demo01-*`, `demo02-*`, …). If you reuse the same cluster, **delete** a demo’s `MaaSSubscription` and `MaaSAuthPolicy` objects before applying another pattern that reuses the same `MaaSModelRef` names and groups, so quota and controller state stay predictable.

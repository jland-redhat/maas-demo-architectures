# Demos (Open Data Hub MaaS)

Each folder is a **governance pattern** for [opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) using real **`maas.opendatahub.io/v1alpha1`** resources. Read [Access and Quota Overview](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/subscription-overview.md) first: **`MaaSAuthPolicy`** = access, **`MaaSSubscription`** = quota; both must allow the request.

**Prerequisite:** deploy upstream MaaS, create **`MaaSModelRef`** + `LLMInferenceService` for each model name you reference (see [model-setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/model-setup.md)).

| Folder | Pattern | What you apply |
|--------|---------|----------------|
| [01-one-to-one](01-one-to-one/) | Line item | One subscription + one policy **per** model; different groups |
| [02-tier-based](02-tier-based/) | Tier + slice | One multi-model subscription; policies **subset** models per team |
| [03-org-catalog](03-org-catalog/) | Org catalog | One subscription owned by **`maas-demo-org`**; team policies slice access |
| [04-model-sku](04-model-sku/) | Multi-SKU owner | Several single-model subscriptions for **same** group; **`priority`** differs |
| [05-quota-overlay](05-quota-overlay/) | Quota emphasis | Tier subscription with **uneven** `tokenRateLimits` per model |
| [06-abac-environment](06-abac-environment/) | Metering labels | `tokenMetadata` / `meteringMetadata` for attribution |

Shared: [shared/models/catalog.yaml](../shared/models/catalog.yaml), [shared/identity/](../shared/identity/).

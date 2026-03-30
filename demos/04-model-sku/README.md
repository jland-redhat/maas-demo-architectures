# Demo 04: Model as SKU (multiple `MaaSSubscription`, one model each)

## Intent (ODH MaaS)

Each **model** is purchased as a **separate SKU**: three **`MaaSSubscription`** resources, each with a **single** `modelRefs` entry. The same team (**`maas-demo-research`**) is **`owner`** on all three so they receive **quota** on each line item. Three **`MaaSAuthPolicy`** resources (one model per policy) grant that group **access**.

**`spec.priority`** differs per subscription so that when a user creates an API key **without** naming `subscription`, the MaaS API can prefer the highest-priority subscription (see [openapi3.yaml](https://github.com/opendatahub-io/models-as-a-service/blob/main/maas-api/openapi3.yaml) and [self-service-model-access](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/user-guide/self-service-model-access.md)). Callers can still **select** a specific subscription with the **`subscription`** field on key creation or use **`X-MaaS-Subscription`** where supported.

## Contrast with Demo 01

Demo 01 assigns **different** groups to **different** SKUs. Demo 04 shows **one** group entitled to **multiple** SKUs (multiple subscriptions, same owner).

## Apply

1. Create **`MaaSModelRef`** for `granite-3-8b-instruct`, `llama-3-1-8b-instruct`, `mistral-7b-instruct-v03` in `llm`.
2. `oc apply -f demos/04-model-sku/manifests/maas-entitlements.yaml`

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | Three subscriptions (priorities 30 / 25 / 20) + three auth policies |

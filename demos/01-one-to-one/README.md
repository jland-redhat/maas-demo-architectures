# Demo 01: One `MaaSSubscription` per model (line-item entitlements)

## Intent (ODH MaaS)

Each **model** is its own commercial line item: one **`MaaSSubscription`** with exactly one entry in `spec.modelRefs`, paired with one **`MaaSAuthPolicy`** that lists the same model and the team that may call it. Subscriptions differ by **`spec.owner`** (who receives quota); policies differ by **`spec.subjects`** (who may access).

This mirrors the upstream [premium simulator sample](https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/maas-system/premium) (one model, one subscription, one policy), repeated for three model names.

## Relationship to upstream CRDs

- **`MaaSSubscription`**: token **quota** for `spec.owner` on that model (`spec.modelRefs[].tokenRateLimits`).
- **`MaaSAuthPolicy`**: **access** for `spec.subjects` to that model.
- Callers still need **`MaaSModelRef`** + `LLMInferenceService` in `llm` for each name — see [model-setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/model-setup.md).

## Mapping in this demo

| Team (OpenShift group) | `MaaSSubscription` | `MaaSAuthPolicy` | `MaaSModelRef` name (in `llm`) |
|------------------------|--------------------|------------------|--------------------------------|
| `maas-demo-research` | `demo01-granite-subscription` | `demo01-granite-access` | `granite-3-8b-instruct` |
| `maas-demo-apps` | `demo01-llama-subscription` | `demo01-llama-access` | `llama-3-1-8b-instruct` |
| `maas-demo-restricted` | `demo01-mistral-subscription` | `demo01-mistral-access` | `mistral-7b-instruct-v03` |

User `alice` is in both research and apps: she can obtain API keys or tokens tied to **either** subscription (see **`spec.priority`** if she omits `subscription` on key creation — [MaaS API](https://github.com/opendatahub-io/models-as-a-service/blob/main/maas-api/openapi3.yaml)).

## Apply

1. Deploy upstream MaaS and create **`MaaSModelRef`** resources for the three names (or rename the YAML to match your models).
2. Ensure groups in [shared/identity/common-openshift-groups.yaml](../../shared/identity/common-openshift-groups.yaml) exist.
3. Apply manifests:

```bash
oc apply -f demos/01-one-to-one/manifests/maas-entitlements.yaml
```

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | Six resources: three subscriptions + three auth policies |

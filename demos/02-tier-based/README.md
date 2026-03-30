# Demo 02: Tier subscription + team-scoped `MaaSAuthPolicy` (subset access)

## Intent (ODH MaaS)

One **`MaaSSubscription`** represents a **tier** (for example “Gold”): `spec.modelRefs` lists **every** model in that tier, and **`spec.owner.groups`** includes every group that should receive **quota** on those models. **Separate `MaaSAuthPolicy` resources** grant each team access to only a **subset** of models.

This is the pattern described in upstream [Access and Quota Overview](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/subscription-overview.md): *“Premium subscription that spans 20 models… policy grants access to only 5 of those models.”*

## Dual check

For each request, the gateway evaluates **policy** (allowed model for user) and **subscription** (quota for owner). The tier subscription gives all listed owners quota on all tier models; users only see models allowed by their policy.

## Mapping

- **`MaaSSubscription`** `demo02-tier-gold`: owners `maas-demo-research`, `maas-demo-apps`, `maas-demo-restricted`; five models in `spec.modelRefs`.
- **`MaaSAuthPolicy`**: `demo02-research-slice`, `demo02-apps-slice`, `demo02-restricted-slice` — each lists a different subset of those models for its team.

## Apply

1. Create **`MaaSModelRef`** for each name in `manifests/maas-entitlements.yaml` in `llm`.
2. Apply groups from [shared/identity](../../shared/identity/).
3. `oc apply -f demos/02-tier-based/manifests/maas-entitlements.yaml`

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | One subscription + three auth policies |

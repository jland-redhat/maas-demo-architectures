# Demo 03: Single enterprise catalog subscription

## Intent (ODH MaaS)

Procurement is **one** platform entitlement: **`MaaSSubscription`** `demo03-org-catalog` is **owned** by a single broad group, **`maas-demo-org`**, and includes the full model list. **Team policies** (`MaaSAuthPolicy`) are **slice** grants for `maas-demo-research`, `maas-demo-apps`, and `maas-demo-restricted` — same mechanism as [Demo 02](../02-tier-based/), but the **story** is “central org catalog” rather than “commercial tier name.”

Technically this is the same tier/subscription pattern as Demo 02; the difference is **who appears in `spec.owner.groups`** (one org-wide group vs. multiple team groups).

## When to use

- Central platform team negotiates one MaaS deal; **all** employees belong to `maas-demo-org` for quota.
- Team RBAC still uses **policies** so R&D does not automatically see every model.

## Apply

1. Ensure `maas-demo-org` and members exist ([shared/identity](../../shared/identity/common-openshift-groups.yaml)).
2. Create **`MaaSModelRef`** for each model name in `manifests/maas-entitlements.yaml`.
3. `oc apply -f demos/03-org-catalog/manifests/maas-entitlements.yaml`

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | One subscription (owner `maas-demo-org`) + three auth policies |

# Demo 05: Heavy quota emphasis on `MaaSSubscription`

## Intent (ODH MaaS)

Same **tier + slice** idea as [Demo 02](../02-tier-based/), but **`spec.modelRefs[].tokenRateLimits`** highlight **per-model** caps (for example stricter limits on a large “GPT-class” model). **`MaaSAuthPolicy`** still defines **who** may call **which** models.

Use this when FinOps wants the YAML to read clearly as **quota-first** (subscriptions), with policies layered for **RBAC**.

## Apply

1. Create all **`MaaSModelRef`** objects referenced in `manifests/maas-entitlements.yaml`.
2. `oc apply -f demos/05-quota-overlay/manifests/maas-entitlements.yaml`

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | Subscription with uneven per-model limits + two auth policies |

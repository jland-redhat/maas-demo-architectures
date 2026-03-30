# Demo 06: Labels and metering metadata (environment / org)

## Intent (ODH MaaS)

**`MaaSSubscription.spec.tokenMetadata`** carries **organization**, **cost center**, and **labels** for **usage attribution** (metering, billing). **`MaaSAuthPolicy.spec.meteringMetadata`** can add **policy-side** labels for **team** or **chargeback** alignment.

This does **not** replace **`MaaSAuthPolicy` / `MaaSSubscription` RBAC**; it enriches telemetry and downstream systems. Pair with separate **`MaaSModelRef`** deployments per environment if you truly isolate **prod** vs **nonprod** clusters or namespaces.

See upstream CRD fields in [maassubscription_types.go](https://github.com/opendatahub-io/models-as-a-service/blob/main/maas-controller/api/maas/v1alpha1/maassubscription_types.go) and [maasauthpolicy_types.go](https://github.com/opendatahub-io/models-as-a-service/blob/main/maas-controller/api/maas/v1alpha1/maasauthpolicy_types.go).

## Apply

1. Create **`MaaSModelRef`** for `llama-3-1-8b-instruct` (two logical environments could be two namespaces in a real cluster; this sample uses one model name — duplicate in a real lab with `llama-3-1-8b-instruct-nonprod` if needed).
2. `oc apply -f demos/06-abac-environment/manifests/maas-entitlements.yaml`

## Files

| File | Role |
|------|------|
| `manifests/maas-entitlements.yaml` | Subscriptions with `tokenMetadata` + policies with `meteringMetadata` |

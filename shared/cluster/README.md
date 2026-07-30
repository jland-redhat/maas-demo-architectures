# Cluster layout (ODH / RHOAI MaaS)

Upstream [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) uses a **tenant-aware** layout (RHOAI / ODH **3.5+**, MaaS **v0.1.2+**):

| Namespace | Typical contents |
|-----------|-------------------|
| **`ai-tenants`** | **`AITenant`** CRs (cluster tenant registry); default `AITenant/models-as-a-service` |
| **`models-as-a-service`** | Default tenant ns: **`MaasTenantConfig/default-tenant`**, **`MaaSSubscription`**, **`MaaSAuthPolicy`** |
| **`llm`** (or other model ns) | **`LLMInferenceService`**, **`ExternalModel`**, **`MaaSModelRef`** — same namespace as the backend |
| **`openshift-ingress`** | Gateway, IPP / payload-processing, singleton **`AuthPolicy/maas-gateway-auth`** |
| **`odh-ai-gateway-infra`** / **`redhat-ai-gateway-infra`** | **`maas-api`** (and DB secret source of truth) after infra-namespace separation |

Additional tenants get namespace **`ai-tenant-{name}`** with their own `MaasTenantConfig`, entitlements, and dedicated Gateway. See [Demo 08](../../demos/08-maas-35-features/) and upstream [Multi-Tenancy](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/concepts/multi-tenancy.md).

Apply `example-namespaces.yaml` if you are not using the operator to create `llm` / `models-as-a-service`:

```bash
oc apply -f shared/cluster/example-namespaces.yaml
oc apply -f shared/identity/common-openshift-groups.yaml
```

Gateway and operators may add other namespaces; see the upstream [Installation Guide](https://opendatahub-io.github.io/models-as-a-service/).

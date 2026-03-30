# Cluster layout (ODH MaaS)

Upstream [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) expects:

| Namespace | Typical contents |
|-----------|-------------------|
| **`llm`** | `LLMInferenceService` (KServe), **`MaaSModelRef`** — one per exposed model |
| **`models-as-a-service`** | MaaS API, **`MaaSSubscription`**, **`MaaSAuthPolicy`** |

Apply `example-namespaces.yaml` if you are not using the operator to create them.

```bash
oc apply -f shared/cluster/example-namespaces.yaml
oc apply -f shared/identity/common-openshift-groups.yaml
```

Gateway and operators may add other namespaces; see the upstream [Deployment Guide](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/README.md).

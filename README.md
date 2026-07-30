# MaaS demo architectures (Open Data Hub Models-as-a-Service)

Demonstration layouts for **[opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/)** (MaaS on OpenShift with Gateway API, KServe `LLMInferenceService`, Kuadrant/Authorino/Limitador, and the MaaS API). This repository does **not** fork upstream; it provides **named patterns**, **sample `MaaSSubscription` / `MaaSAuthPolicy` YAML**, and **identity** notes you can layer on after you deploy the stack.

**Demo lab users:** `alice`, `bob`, `chloe`, `dana` — sample identities you create in your IdP (for example HTPasswd). They are not special to OpenShift; **group membership** drives MaaS entitlements. Each [demos/](demos/) pattern documents **which OpenShift `Group` objects** apply in that scenario; the canonical declaration for a **full** lab (all groups at once) is [shared/identity/common-openshift-groups.yaml](shared/identity/common-openshift-groups.yaml) (duplicated in [deploy/base/groups.yaml](deploy/base/groups.yaml) for Kustomize).

## Deploy the product first

Follow the upstream project:

- Repository: [github.com/opendatahub-io/models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/)
- Quick start: `./scripts/deploy.sh` (see upstream README for `--operator-type`, `--deployment-mode`, etc.)
- Online docs: [opendatahub-io.github.io/models-as-a-service](https://opendatahub-io.github.io/models-as-a-service/)
- Prerequisites: OpenShift **4.19.9+**, PostgreSQL for production API keys (see upstream [Database Prerequisites](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/prerequisites.md))

## How access works in ODH MaaS

The controller and gateway enforce a **dual check** (see upstream [Access and Quota Overview](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/subscription-overview.md)):

| Concern | CRD | Role |
|---------|-----|------|
| **Access** | `MaaSAuthPolicy` | Who may call which models (`spec.subjects`) |
| **Quota** | `MaaSSubscription` | Token rate limits per model for owners (`spec.owner` + `spec.modelRefs`) |
| **Catalog** | `MaaSModelRef` | Registers backends (`LLMInferenceService` or `ExternalModel`) in the **model** namespace (usually `llm`) |
| **Tenancy** | `AITenant` + `MaasTenantConfig` | Platform tenant registry (`ai-tenants`) + runtime config in the tenant namespace |

`MaaSAuthPolicy` and `MaaSSubscription` live in a **tenant namespace** that contains **`MaasTenantConfig/default-tenant`** (default: **`models-as-a-service`**). They reference `MaaSModelRef` by **`name` + `namespace`** (often `llm`). You need **both** a matching policy and subscription for a caller to succeed. [Demo 08](demos/08-maas-35-features/) adds **`partner`** and **`oidc`** tenants (OIDC uses upstream Keycloak samples).

**API keys:** programmatic clients (including agents) use **`sk-oai-*`** keys minted via `POST /v1/api-keys` while authenticated with OpenShift. Each key stores the caller’s groups and is **bound to one subscription**; use the optional **`subscription`** field at mint time when a user owns several (see [Demo 02](demos/02-tier-based/) and [Demo 07](demos/07-openclaw-agent/)).

**Inference (RHOAI / ODH 3.5+):** prefer **body-based routing** — `POST https://maas.<domain>/v1/chat/completions` with the model **`id`** in the JSON body (requires IPP). Path-based URLs (`…/llm/<name>/v1/chat/completions`) still work. Details in [Demo 08](demos/08-maas-35-features/).

## Contents of this repo

| Path | Purpose |
|------|---------|
| [infra/](infra/README.md) | Lab prerequisites: **Kuadrant CR**, **Gateway + TLS**, **Authorino TLS**, **PostgreSQL** / `maas-db-config`, **DSCI metrics** (Showback) |
| [shared/models/catalog.yaml](shared/models/catalog.yaml) | Realistic model **display** names and suggested **`MaaSModelRef` metadata names** |
| [shared/identity/](shared/identity/) | OpenShift `Group` samples and optional `htpasswd` helper for labs |
| [shared/cluster/](shared/cluster/) | Namespace layout (`llm`, `models-as-a-service`, `ai-tenants`) |
| [demos/](demos/) | Eight patterns (governance + 3.5 gateway features); each includes `manifests/required-groups.yaml`, entitlements, and README |
| [deploy/](deploy/README.md) | **Kustomize** install: five simulator `LLMInferenceService` + `MaaSModelRef`, groups, and entitlements |

## Lab infra (before demos)

Kuadrant instance, default gateway TLS, Authorino TLS, PostgreSQL, and DSCI monitoring (Showback/FinOps):

```bash
./infra/scripts/install-infra.sh
```

Or piecemeal: `./infra/scripts/setup-postgres.sh`, `./infra/scripts/setup-observability.sh`. See [infra/README.md](infra/README.md).

## Install simulators, model refs, groups, and entitlements

After upstream MaaS is running, apply this repository’s workloads from the **repo root** (see [deploy/README.md](deploy/README.md) for overlays and flags):

```bash
oc apply -k .
```

That uses the root [kustomization.yaml](kustomization.yaml) (default: Demo 01). For other demos or `models-only`, use the commands in [deploy/README.md](deploy/README.md).

**Tokens / impersonation:** you cannot mint another user’s OAuth token without their login; use **`oc login`** as that user, **`--as` / `--as-group`** for admin checks, or **ServiceAccount** tokens for workloads — see [deploy/README.md](deploy/README.md#can-i-get-a-token-for-another-user).

## Container helper (lab IdP)

### Using Podman (recommended)

```bash
chmod +x shared/identity/htpasswd-sample-users.sh
./shared/identity/htpasswd-sample-users.sh > /tmp/maas-demo-htpasswd
```

### Docker alternative

```bash
chmod +x shared/identity/htpasswd-sample-users.sh
# Edit the script to use `docker` instead of `podman`, then run the same command.
```

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE).

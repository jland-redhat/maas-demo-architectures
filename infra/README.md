# Lab infrastructure (prerequisites)

Cluster prerequisites for this demo repo that are **not** demo entitlements: Kuadrant instance, default Gateway + TLS, Authorino TLS, PostgreSQL, and DSCI monitoring (Showback/FinOps).

Start here **before** [deploy/](../deploy/README.md) overlays if `maas-api` / gateway policy pieces are incomplete.

| Path | Purpose |
|------|---------|
| [kuadrant/](kuadrant/) | `Kuadrant` CR (`kuadrant` / `kuadrant-system` or RHCL ns) |
| [postgres/](postgres/) | POC PostgreSQL in namespace **`postgres`** |
| [observability/](observability/) | COO + OpenTelemetry operators; DSCI `metrics.storage` patch; Perses dashboard NetworkPolicy |
| [hacks/](hacks/) | **Not** official install — one-off lab skew notes/scripts (e.g. Perses TLS) |
| [scripts/install-infra.sh](scripts/install-infra.sh) | **Install everything** (recommended) |
| [scripts/setup-kuadrant.sh](scripts/setup-kuadrant.sh) | Apply Kuadrant CR only |
| [scripts/setup-gateway.sh](scripts/setup-gateway.sh) | `maas-default-gateway` + TLS cert detection |
| [scripts/setup-authorino-tls.sh](scripts/setup-authorino-tls.sh) | Authorino serving-cert + outbound service CA (from upstream) |
| [scripts/setup-authorino-oidc-ca.sh](scripts/setup-authorino-oidc-ca.sh) | Mount ingress CA into Authorino for Keycloak OIDC discovery |
| [scripts/setup-postgres.sh](scripts/setup-postgres.sh) | Postgres + **`maas-db-config`** |
| [scripts/setup-observability.sh](scripts/setup-observability.sh) | DSCI metrics + OTEL repair → MonitoringStackAvailable / Showback |
| [scripts/ensure-maasmodelref-tenantref.sh](scripts/ensure-maasmodelref-tenantref.sh) | Patch `MaaSModelRef` CRD so `spec.tenantRef` is accepted (multi-tenant gateways) |
| [scripts/ensure-gateway-allowed-routes.sh](scripts/ensure-gateway-allowed-routes.sh) | Re-assert Gateway `allowedRoutes.from: All` (AIGateway can narrow it and block `llm` HTTPRoutes) |

**Not included:** installing ODH/RHOAI, the Kuadrant/RHCL **operator**, or MaaS itself — use upstream [`deploy.sh`](https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/deploy.sh) / [platform-setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/platform-setup.md).

## Quick start (all steps)

From the **repository root**:

```bash
./infra/scripts/install-infra.sh
```

That runs, in order:

1. **Kuadrant CR** — reconciles Authorino + Limitador (operator must already exist)
2. **Gateway** — `maas-default-gateway` in `openshift-ingress` with router TLS + `security.opendatahub.io/authorino-tls-bootstrap: "true"`
3. **Authorino TLS** — OpenShift serving-cert on Authorino + SSL CA env for calls to `maas-api`
4. **PostgreSQL** — namespace `postgres` + Secret **`maas-db-config`** (`DB_CONNECTION_URL`)
5. **Observability** — COO + OpenTelemetry, DSCI `metrics.storage` (fixes `MetricsNotConfigured` / Showback)

Skip individual steps:

```bash
SKIP_GATEWAY=1 ./infra/scripts/install-infra.sh
SKIP_POSTGRES=1 ./infra/scripts/install-infra.sh
SKIP_OBSERVABILITY=1 ./infra/scripts/install-infra.sh
INGRESS_MODE=clusterip ./infra/scripts/install-infra.sh   # on-prem / bare-metal
```

Prefer upstream scripts when you have a MaaS checkout:

```bash
export MAAS_REPO=/path/to/models-as-a-service
./infra/scripts/install-infra.sh
# uses ${MAAS_REPO}/scripts/setup-gateway.sh and setup-authorino-tls.sh when executable
```

## Individual scripts

```bash
./infra/scripts/setup-kuadrant.sh
./infra/scripts/setup-gateway.sh
./infra/scripts/setup-authorino-tls.sh
./infra/scripts/setup-postgres.sh
./infra/scripts/setup-observability.sh
```

### Kuadrant

Creates `Kuadrant/kuadrant` in `kuadrant-system` (ODH) or `rh-connectivity-link` (RHOAI/RHCL). Auto-detects namespace; override with `KUADRANT_NAMESPACE=…`.

### Gateway TLS

Route mode (default, ROSA/OSD/cloud) reuses the cluster router certificate (IngressController → router deployment → known secret names → self-signed fallback), matching upstream [setup-gateway.sh](https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-gateway.sh).

```bash
CERT_NAME=my-wildcard-tls ./infra/scripts/setup-gateway.sh
CLUSTER_DOMAIN=apps.example.com ./infra/scripts/setup-gateway.sh
```

### Authorino TLS

Vendored from upstream [`setup-authorino-tls.sh`](https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-authorino-tls.sh). Docs: [TLS Configuration](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/tls-configuration.md).

```bash
AUTHORINO_NAMESPACE=rh-connectivity-link ./infra/scripts/setup-authorino-tls.sh
```

### Authorino OIDC / ingress CA (External OIDC)

Keycloak is served on the OpenShift apps route. Authorino must trust the **ingress CA** to fetch `/.well-known/openid-configuration` and JWKS. `setup-authorino-tls.sh` only covers the **service CA** (maas-api). For External OIDC:

```bash
./infra/scripts/setup-authorino-oidc-ca.sh
```

This builds a combined service-ca + ingress CA bundle, mounts it on `deployment/authorino`, and sets `SSL_CERT_FILE`. Demo 08’s `apply-oidc-tenant.sh` runs it automatically.

### PostgreSQL

See below — connection string shape matches upstream `setup-database.sh`:

```text
postgresql://USER:PASSWORD@postgres.postgres.svc.cluster.local:5432/DB?sslmode=disable
```

`setup-postgres.sh` writes **`maas-db-config`** into each of these namespaces that already exist:

- `redhat-ai-gateway-infra` (RHOAI)
- `odh-ai-gateway-infra` (ODH)
- optionally controller namespaces (`redhat-ods-applications`, `opendatahub`)

### Observability (Showback / FinOps)

Empty DSCI `spec.monitoring.metrics: {}` yields:

```text
MonitoringStackAvailable=False  reason=MetricsNotConfigured
```

`setup-observability.sh` installs COO + OpenTelemetry (if needed), **repairs a stuck OpenTelemetry CSV when CRDs are missing**, patches DSCI with `metrics.storage` (`5Gi` / `15d` by default), enables User Workload Monitoring, Kuadrant `observability.enable`, the dashboard `observabilityDashboard` flag, and a Perses NetworkPolicy so the AI Dashboard can reach Perses.

```bash
./infra/scripts/setup-observability.sh
METRICS_SIZE=10Gi METRICS_RETENTION=30d ./infra/scripts/setup-observability.sh
SKIP_OPERATORS=1 ./infra/scripts/setup-observability.sh   # operators already installed
```

#### Common lab failures this script fixes

| Symptom | Cause | Fix in script |
|---------|--------|----------------|
| Dashboard: `Unexpected token '<', "<!doctype "... is not valid JSON` (Perses timeouts) | Perses NetworkPolicy only allows `perses-operator`; AI Dashboard calls time out and the UI parses an HTML error page as JSON | Applies `perses-dashboard-access` NetworkPolicy (dashboard / console / ingress → Perses `:8080`) |
| `Monitoring` `Ready=False` / `OpenTelemetryCollectorCRDNotFoundReason` | OpenTelemetry Subscription stuck (`Pending` / `RequirementsNotMet`) with CRDs missing | Deletes stuck CSV/InstallPlan and re-applies `opentelemetry-product` |

> **Product gap (not in this repo):** RHOAI may omit an HTTPRoute that maps `data-science-gateway` `/observability/api` → Perses `/api`. Without that route the SPA HTML is returned for API calls. Fix upstream / on-cluster; do not bake into demo infra.
>
> **Lab skew (hack, not install):** Perses CrashLoop on `--web.tls-min-version`, or a leftover `perses-tls-workaround` that keeps `perses-operator` at 0 (breaks conversion webhooks) — see [hacks/perses-tls-skew.hack.sh](hacks/perses-tls-skew.hack.sh).

Reference: [Managing observability (RHOAI)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai), upstream [observability setup](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/observability/setup.md).

## Verify

```bash
oc get kuadrant -A
oc get gateway maas-default-gateway -n openshift-ingress
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls}{"\n"}'
# or: -n rh-connectivity-link
oc get pods,svc,secret -n postgres
oc get secret maas-db-config -n redhat-ai-gateway-infra   # RHOAI
oc get secret maas-db-config -n odh-ai-gateway-infra      # ODH
oc get dscinitialization default-dsci \
  -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")]}{"\n"}'
oc get monitoring -A
oc get monitoringstack -A
oc get pods -n redhat-ods-monitoring   # RHOAI; ODH may use opendatahub
oc get csv -n openshift-operators | grep opentelemetry
oc get crd opentelemetrycollectors.opentelemetry.io
```

If `maas-api` was already running when the Secret was missing or wrong, restart it after setup:

```bash
# RHOAI
oc rollout restart deployment -n redhat-ai-gateway-infra -l app.kubernetes.io/name=maas-api
# ODH
oc rollout restart deployment -n odh-ai-gateway-infra -l app.kubernetes.io/name=maas-api
```

## Upstream alternative

Full product install (operators + MaaS) still lives upstream:

```bash
export MAAS_REPO=/path/to/models-as-a-service
"${MAAS_REPO}/scripts/deploy.sh" --operator-type rhoai   # or odh
# Piecemeal:
"${MAAS_REPO}/scripts/setup-database.sh"
"${MAAS_REPO}/scripts/setup-gateway.sh"
AUTHORINO_NAMESPACE=rh-connectivity-link "${MAAS_REPO}/scripts/setup-authorino-tls.sh"
```

Docs: [MaaS Components](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md), [Infrastructure namespace separation](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/configuration-and-management/infra-namespace-migration.md).

## Production note

Do **not** use this POC Postgres for production. Prefer RDS / Crunchy / Azure Database and create `maas-db-config` yourself with `sslmode=require` (or your provider’s TLS settings).

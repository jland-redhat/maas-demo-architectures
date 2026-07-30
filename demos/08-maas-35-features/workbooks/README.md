# Demo 08 workbooks (Jupyter)

Notebooks for **body-based routing**, **external models**, **multi-tenancy**, and **External OIDC**. Same style as the [3.4 maas-basic-demo](../../../../3.4/maas-basic-demo/) workbooks: Python 3.9+ **stdlib only**, **Demo quick swap** cells, no `oc` inside the kernel.

## Prerequisites

1. Bootstrap tenants:

   ```bash
   ./demos/08-maas-35-features/scripts/apply-partner-tenant.sh --with-default
   export MAAS_REPO=/path/to/models-as-a-service   # upstream checkout
   ./demos/08-maas-35-features/scripts/apply-oidc-tenant.sh
   ```

2. Upload notebooks to a RHOAI workbench / Jupyter.
3. For external-model cells: confirm IPP in `openshift-ingress` and that `sim-chat` / `sim-messages` are Ready (llm-katan; no real cloud keys).

**`oc` stays on your laptop.** Paste `oc whoami -t` (alice/bob) into quick-swap cells as needed. For **ExternalOIDC**, use Keycloak **`alice_lead`** / **`letmein`** (upstream test realm — lab only).

## Notebooks

| Notebook | Purpose |
|----------|---------|
| [BodyBasedRouting.ipynb](BodyBasedRouting.ipynb) | Default tenant: OpenShift auth → mint key → **BBR** → path-based contrast |
| [BodyBasedRouting-no-key.ipynb](BodyBasedRouting-no-key.ipynb) | Same with a pre-provisioned `sk-oai-*` |
| [ExternalModels.ipynb](ExternalModels.ipynb) | External **sim-chat** (llm-katan; BBR default; flip `USE_BBR` for path-based) |
| [TenancyLayout.ipynb](TenancyLayout.ipynb) | Default + partner catalogs and isolation |
| [ExternalOIDC.ipynb](ExternalOIDC.ipynb) | Keycloak **tenant-a** → mint key on **oidc** tenant → BBR |

## Quick swap variables

| Variable | Used by | Meaning |
|----------|---------|---------|
| `DEMO_MAAS_BASE` | BBR / External | Default gateway origin |
| `DEMO_DEFAULT_BASE` / `DEMO_PARTNER_BASE` | TenancyLayout | OpenShift tenant gateways |
| `DEMO_OIDC_BASE` / `DEMO_KEYCLOAK_HOST` | ExternalOIDC | `oidc-maas.<domain>` and `keycloak.<domain>` |
| `DEMO_OPENSHIFT_TOKEN` | BodyBasedRouting | alice token for key mint |
| `DEMO_ALICE_TOKEN` / `DEMO_BOB_TOKEN` | TenancyLayout | Tokens to mint per-tenant keys |
| `DEMO_API_KEY` / … | no-key / Tenancy | Existing `sk-oai-*` keys |
| `USE_BBR` | ExternalModels | `True` → `/v1/chat/completions` |

Environment alternatives: `MAAS_BASE`, `MAAS_PARTNER_BASE`, `MAAS_OIDC_BASE`, `KEYCLOAK_HOST`, `OPENSHIFT_TOKEN`, `MAAS_API_KEY` / `API_KEY`, `VERIFY_TLS=1`.

## Suggested presenter order

1. **TenancyLayout** — two OpenShift tenants + isolation.
2. **ExternalOIDC** — Keycloak `alice_lead` → oidc tenant (must-show for External OIDC).
3. **BodyBasedRouting** — default-tenant BBR + model switch.
4. **ExternalModels** — llm-katan ExternalModel + IPP credential injection.

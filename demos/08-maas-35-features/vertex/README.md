# Demo 08 side lab: live Vertex Claude (Opus 4.8)

Optional add-on for [Demo 08](../). Creates a **real** Google Vertex AI `ExternalProvider` + `ExternalModel` (Claude Opus 4.8 via Anthropic on Vertex), wires a `MaaSModelRef`, and entitles the **default** tenant (`models-as-a-service`) with a subscription and auth policy.

Does **not** replace the llm-katan simulator models; it sits beside them in `llm`.

## Prerequisites

1. Demo 08 default tenant applied (`llm` + `models-as-a-service` exist):

   ```bash
   ./demos/08-maas-35-features/scripts/apply-default-tenant.sh
   ```

2. A GCP service-account JSON key with Vertex AI access for project `ai-eng-ci-vertex`, saved as:

   ```text
   demos/08-maas-35-features/vertex/vertex.json
   ```

   (`vertex.json` is gitignored. Use `vertex.json.example` as a shape reference.)

## Apply

```bash
./demos/08-maas-35-features/vertex/scripts/apply.sh
```

What the script does:

1. Creates / updates Secret `vertex-sa-key` in `llm` from `vertex.json` (`gcp-service-account-json` key)
2. Labels it `inference.llm-d.ai/ipp-managed=true`
3. Applies `ExternalProvider` `vertex`, `ExternalModel` / `MaaSModelRef` `vertex-claude-opus-4-8`
4. Applies `MaaSSubscription` `demo08-vertex-claude` + `MaaSAuthPolicy` `demo08-vertex-claude-access` in `models-as-a-service`

## Manifests

| File | Purpose |
|------|---------|
| `manifests/external-provider.yaml` | `ExternalProvider` `vertex` (`oauth2`, project `ai-eng-ci-vertex`, location `global`) |
| `manifests/external-model.yaml` | `ExternalModel` Claude Opus 4.8 (`vertex-messages` → `:rawPredict`) |
| `manifests/maas-modelref.yaml` | Catalog `MaaSModelRef` |
| `manifests/maas-entitlements.yaml` | Subscription + auth for `maas-admin` / `maas-demo-research` |

## Quick verify

```bash
oc get externalprovider vertex -n llm
oc get externalmodel,maasmodelref vertex-claude-opus-4-8 -n llm
oc get maassubscription demo08-vertex-claude -n models-as-a-service
oc get maasauthpolicy demo08-vertex-claude-access -n models-as-a-service
```

List subscriptions, then mint a key against the Vertex subscription (default gateway):

```bash
# GATEWAY_HOST=maas.<cluster-domain>
OC_TOKEN=$(oc whoami -t)

# Expect demo08-vertex-claude (plus any other default-tenant subscriptions you can access)
curl -sSk -H "Authorization: Bearer ${OC_TOKEN}" \
  "https://${GATEWAY_HOST}/maas-api/v1/subscriptions" | jq .

curl -sS "https://${GATEWAY_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer ${OC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"demo08-vertex","subscription":"demo08-vertex-claude","expiresIn":"30d"}'
```

## Tear down

```bash
oc delete maassubscription demo08-vertex-claude -n models-as-a-service --ignore-not-found
oc delete maasauthpolicy demo08-vertex-claude-access -n models-as-a-service --ignore-not-found
oc delete maasmodelref,externalmodel vertex-claude-opus-4-8 -n llm --ignore-not-found
oc delete externalprovider vertex -n llm --ignore-not-found
oc delete secret vertex-sa-key -n llm --ignore-not-found
```

#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Apply Demo 08 default (main) tenant only: on-cluster sims + llm-katan ExternalModels
# + hybrid catalog entitlements in models-as-a-service / llm.
# Does not create partner or OIDC tenants.
#
# Usage (from repo root):
#   ./demos/08-maas-35-features/scripts/apply-default-tenant.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: oc is required" >&2
  exit 1
fi

echo "Applying Demo 08 default-tenant overlay (deploy/overlays/demo08)…"
oc kustomize --load-restrictor LoadRestrictionsNone "${REPO_ROOT}/deploy/overlays/demo08" | oc apply -f -

echo "Applying Demo 08 required OpenShift groups…"
oc apply -f "${DEMO_DIR}/manifests/required-groups.yaml"

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
GATEWAY_HOST="maas.${CLUSTER_DOMAIN:-<cluster-domain>}"

echo ""
echo "Default tenant apply complete."
echo "  Gateway host:   https://${GATEWAY_HOST}"
echo "  Tenant ns:      models-as-a-service"
echo "  Models ns:      llm"
echo "  Subscription:   demo08-hybrid-catalog"
echo "  External sims:  sim-chat, sim-chat-2, sim-messages (llm-katan)"
echo ""
echo "Verify:"
echo "  oc get maasmodelref -n llm"
echo "  oc get externalmodel,externalprovider -n llm"
echo "  oc get maassubscription,maasauthpolicy -n models-as-a-service"
echo ""
echo "Partner / OIDC tenants (optional):"
echo "  ./demos/08-maas-35-features/scripts/apply-partner-tenant.sh"
echo "  ./demos/08-maas-35-features/scripts/apply-oidc-tenant.sh"
echo "  ./demos/08-maas-35-features/scripts/apply-all.sh"

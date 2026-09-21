#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Apply Demo 09: multi-replica llm-d-inference-sim with router.scheduler (EPP).
#
# Usage (from repo root):
#   ./demos/09-llm-d-epp/scripts/apply.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,12p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: oc is required" >&2
  exit 1
fi

if [[ -x "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" ]]; then
  echo "Ensuring maas-default-gateway allows HTTPRoutes from All namespaces…"
  "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" maas-default-gateway
fi

echo "Applying Demo 09 overlay (deploy/overlays/demo09)…"
oc kustomize --load-restrictor LoadRestrictionsNone "${REPO_ROOT}/deploy/overlays/demo09" | oc apply -f -

echo "Applying Demo 09 required OpenShift groups…"
oc apply -f "${DEMO_DIR}/manifests/required-groups.yaml"

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
GATEWAY_HOST="maas.${CLUSTER_DOMAIN:-<cluster-domain>}"

echo ""
echo "Demo 09 apply complete."
echo "  Gateway host:   https://${GATEWAY_HOST}"
echo "  Model:          demo09-epp-sim (replicas=3, router.scheduler={})"
echo "  Subscription:   demo09-epp-catalog"
echo ""
echo "Validate EPP path:"
echo "  ./demos/09-llm-d-epp/scripts/validate-epp.sh"

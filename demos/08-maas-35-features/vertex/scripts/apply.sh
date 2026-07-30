#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Apply Demo 08 live Vertex Claude model (ExternalProvider + ExternalModel +
# MaaSModelRef + default-tenant subscription/auth policy).
#
# Prerequisites:
#   - Default tenant / llm namespace already applied (apply-default-tenant.sh)
#   - vertex.json (GCP SA key) in the vertex/ folder next to this README
#
# Usage (from repo root):
#   ./demos/08-maas-35-features/vertex/scripts/apply.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERTEX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFESTS="${VERTEX_DIR}/manifests"
VERTEX_JSON="${VERTEX_DIR}/vertex.json"
NS_MODELS=llm
SECRET_NAME=vertex-sa-key

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,16p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: oc is required" >&2
  exit 1
fi

if [[ ! -f "${VERTEX_JSON}" ]]; then
  echo "Error: missing ${VERTEX_JSON}" >&2
  echo "Copy your GCP service-account JSON key to that path (see vertex.json.example)." >&2
  exit 1
fi

if ! oc get ns "${NS_MODELS}" >/dev/null 2>&1; then
  echo "Error: namespace ${NS_MODELS} not found — apply the Demo 08 default tenant first:" >&2
  echo "  ./demos/08-maas-35-features/scripts/apply-default-tenant.sh" >&2
  exit 1
fi

echo "Creating / updating secret ${SECRET_NAME} in ${NS_MODELS} from vertex.json…"
oc create secret generic "${SECRET_NAME}" \
  --from-file=gcp-service-account-json="${VERTEX_JSON}" \
  -n "${NS_MODELS}" \
  --dry-run=client -o yaml | oc apply -f -

oc label secret "${SECRET_NAME}" \
  inference.llm-d.ai/ipp-managed=true \
  app.kubernetes.io/part-of=maas-demo-architectures \
  -n "${NS_MODELS}" \
  --overwrite

echo "Applying Vertex ExternalProvider / ExternalModel / MaaSModelRef…"
oc apply -f "${MANIFESTS}/external-provider.yaml"
oc apply -f "${MANIFESTS}/external-model.yaml"
oc apply -f "${MANIFESTS}/maas-modelref.yaml"

echo "Applying default-tenant subscription + auth policy…"
oc apply -f "${MANIFESTS}/maas-entitlements.yaml"

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
GATEWAY_HOST="maas.${CLUSTER_DOMAIN:-<cluster-domain>}"

echo ""
echo "Vertex apply complete."
echo "  Gateway host:   https://${GATEWAY_HOST}"
echo "  Provider:       vertex (llm)"
echo "  Model:          vertex-claude-opus-4-8"
echo "  Subscription:   demo08-vertex-claude"
echo "  Auth policy:    demo08-vertex-claude-access"
echo ""
echo "Verify:"
echo "  oc get externalprovider,externalmodel,maasmodelref -n llm | grep vertex"
echo "  oc get maassubscription,maasauthpolicy -n models-as-a-service | grep vertex"
echo "  oc get secret ${SECRET_NAME} -n ${NS_MODELS}"

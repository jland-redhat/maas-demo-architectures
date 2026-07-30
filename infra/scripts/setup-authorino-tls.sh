#!/usr/bin/env bash
#
# Configure Authorino for TLS communication with maas-api.
#
# Vendored from upstream models-as-a-service (keep in sync):
#   https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-authorino-tls.sh
#
# When maas-api serves HTTPS (TLS backend), Authorino must:
# 1. Enable TLS on its listener so it accepts HTTPS auth requests
# 2. Trust the OpenShift service CA when making outbound requests to maas-api
#    (e.g., API key validation at https://maas-api...:8443/internal/v1/api-keys/validate)
#
# This script patches operator-managed Authorino resources that cannot be
# modified via Kustomize. Upstream deploy.sh runs the equivalent when
# --enable-tls-backend is set (default).
#
# Prerequisites:
# - Authorino operator installed (Kuadrant or RHCL)
# - OpenShift cluster (uses service-ca for certificate provisioning)
#
# Environment variables:
#   AUTHORINO_NAMESPACE  Authorino namespace (auto-detected if unset)
#                        kuadrant-system (ODH/Kuadrant) or rh-connectivity-link (RHCL)
#
# Usage (from repo root):
#   ./infra/scripts/setup-authorino-tls.sh
#   AUTHORINO_NAMESPACE=rh-connectivity-link ./infra/scripts/setup-authorino-tls.sh
#

set -euo pipefail

OC="${OC:-}"
if [[ -z "${OC}" ]]; then
  if command -v oc &>/dev/null; then
    OC=oc
  elif command -v kubectl &>/dev/null; then
    OC=kubectl
  else
    echo "ERROR: oc or kubectl required" >&2
    exit 1
  fi
fi

detect_authorino_namespace() {
  if [[ -n "${AUTHORINO_NAMESPACE:-}" ]]; then
    echo "${AUTHORINO_NAMESPACE}"
    return 0
  fi
  for ns in rh-connectivity-link kuadrant-system; do
    if ${OC} get authorino authorino -n "${ns}" &>/dev/null; then
      echo "${ns}"
      return 0
    fi
  done
  # Fallback default (ODH)
  echo "kuadrant-system"
}

NAMESPACE="$(detect_authorino_namespace)"

echo "🔐 Configuring Authorino TLS in namespace: ${NAMESPACE}"

if ! ${OC} get authorino authorino -n "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: Authorino CR 'authorino' not found in ${NAMESPACE}" >&2
  echo "  Apply the Kuadrant CR first: ./infra/scripts/setup-kuadrant.sh" >&2
  exit 1
fi

if ! ${OC} get service authorino-authorino-authorization -n "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: Service authorino-authorino-authorization not found in ${NAMESPACE}" >&2
  echo "  Wait for the Kuadrant operator to reconcile Authorino, then retry." >&2
  exit 1
fi

echo "📝 Adding serving-cert annotation to Authorino service..."
${OC} annotate service authorino-authorino-authorization \
  -n "${NAMESPACE}" \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  --overwrite

echo "🔧 Patching Authorino CR for TLS listener..."
${OC} patch authorino authorino -n "${NAMESPACE}" --type=merge --patch '
{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'

# Note: The Authorino CR doesn't support envVars, so we patch the deployment directly.
# External OIDC (Keycloak on the apps route) also needs the ingress CA — run
# ./infra/scripts/setup-authorino-oidc-ca.sh afterward (or via apply-oidc-tenant.sh).
# That script replaces SSL_CERT_FILE with a combined service-ca + ingress CA bundle.
echo "🌍 Adding environment variables to Authorino deployment..."
${OC} -n "${NAMESPACE}" set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

echo "✅ Authorino TLS configuration complete"
echo "  For External OIDC / Keycloak: ./infra/scripts/setup-authorino-oidc-ca.sh"
echo ""
echo "  Restart maas-api and authorino deployments to pick up TLS configuration:"
echo "    ${OC} rollout restart deployment -n redhat-ai-gateway-infra -l app.kubernetes.io/name=maas-api"
echo "    ${OC} rollout restart deployment -n odh-ai-gateway-infra -l app.kubernetes.io/name=maas-api"
echo "    ${OC} rollout restart deployment/authorino -n ${NAMESPACE}"

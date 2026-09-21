#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Demo 08 — third tenant with External OIDC (Keycloak).
#
# Keycloak install + test realms are NOT forked here. This script calls the upstream
# models-as-a-service samples exactly:
#   ./scripts/setup-keycloak.sh
#   ./docs/samples/install/keycloak/test-realms/apply-test-realms.sh
# Docs:
#   https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/install/keycloak
#   https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/advanced-administration/external-oidc.md
#
# Then it mounts the OpenShift ingress CA into Authorino (OIDC JWKS discovery),
# creates AITenant/oidc with spec.oidc → realm tenant-a (client test-client),
# plus llm-oidc models and entitlements for Keycloak groups Engineering / Project-Alpha.
#
# Usage (from repo root):
#   export MAAS_REPO=/path/to/models-as-a-service
#   ./demos/08-maas-35-features/scripts/apply-oidc-tenant.sh
#   ./demos/08-maas-35-features/scripts/apply-oidc-tenant.sh --skip-keycloak   # tenant only
#
set -euo pipefail

TENANT_NAME="oidc"
AITENANT_NAMESPACE="ai-tenants"
GATEWAY_NAMESPACE="openshift-ingress"
TENANT_NAMESPACE="ai-tenant-${TENANT_NAME}"
OIDC_REALM="tenant-a"
OIDC_CLIENT_ID="test-client"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKIP_KEYCLOAK=false
GATEWAY_HOSTNAME=""

for arg in "$@"; do
  case "$arg" in
    --skip-keycloak) SKIP_KEYCLOAK=true ;;
    --help|-h)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "${GATEWAY_HOSTNAME}" && "${arg}" != --* ]]; then
        GATEWAY_HOSTNAME="${arg}"
      fi
      ;;
  esac
done

resolve_maas_repo() {
  if [[ -n "${MAAS_REPO:-}" && -x "${MAAS_REPO}/scripts/setup-keycloak.sh" ]]; then
    echo "${MAAS_REPO}"
    return 0
  fi
  local cand
  for cand in \
    "${HOME}/Documents/RedHat/maas/tools/models-as-a-service" \
    "${HOME}/Documents/Opensource Contributions/models-as-a-service" \
    "${DEMO_DIR}/../../../maas/tools/models-as-a-service" \
    "${DEMO_DIR}/../../models-as-a-service"
  do
    if [[ -x "${cand}/scripts/setup-keycloak.sh" ]]; then
      echo "${cand}"
      return 0
    fi
  done
  return 1
}

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: could not detect cluster domain" >&2
  exit 1
fi

if [[ -z "${GATEWAY_HOSTNAME}" ]]; then
  GATEWAY_HOSTNAME="${TENANT_NAME}-maas.${CLUSTER_DOMAIN}"
fi
KEYCLOAK_HOST="keycloak.${CLUSTER_DOMAIN}"
OIDC_ISSUER_URL="https://${KEYCLOAK_HOST}/realms/${OIDC_REALM}"

echo "OIDC tenant gateway : https://${GATEWAY_HOSTNAME}"
echo "Keycloak issuer     : ${OIDC_ISSUER_URL}"
echo "OIDC clientId       : ${OIDC_CLIENT_ID} (upstream test-client)"
echo ""

#──────────────────────────────────────────────────────────────────────────────
# Upstream Keycloak (exact scripts from models-as-a-service)
#──────────────────────────────────────────────────────────────────────────────

if [[ "${SKIP_KEYCLOAK}" != "true" ]]; then
  if ! MAAS_REPO="$(resolve_maas_repo)"; then
    echo "Error: set MAAS_REPO to a checkout of opendatahub-io/models-as-a-service" >&2
    echo "  git clone https://github.com/opendatahub-io/models-as-a-service.git" >&2
    echo "  export MAAS_REPO=\$PWD/models-as-a-service" >&2
    echo "Or re-run with --skip-keycloak if Keycloak + test realms are already installed." >&2
    exit 1
  fi
  echo "Using upstream MaaS repo: ${MAAS_REPO}"
  echo "→ Running scripts/setup-keycloak.sh (upstream)…"
  (
    cd "${MAAS_REPO}"
    ./scripts/setup-keycloak.sh
  )
  echo "→ Running docs/samples/install/keycloak/test-realms/apply-test-realms.sh (upstream)…"
  (
    cd "${MAAS_REPO}"
    ./docs/samples/install/keycloak/test-realms/apply-test-realms.sh
  )
else
  echo "Skipping Keycloak (--skip-keycloak). Expect realm ${OIDC_REALM} at ${KEYCLOAK_HOST}."
fi

#──────────────────────────────────────────────────────────────────────────────
# Authorino must trust the OpenShift ingress CA to fetch Keycloak OIDC discovery
# (issuerUrl is https://keycloak.<apps-domain>/…). Without this, JWT auth fails
# with x509 unknown authority and falls through to a 401.
#──────────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"
AUTHORINO_OIDC_CA_SCRIPT="${REPO_ROOT}/infra/scripts/setup-authorino-oidc-ca.sh"
if [[ -x "${AUTHORINO_OIDC_CA_SCRIPT}" ]]; then
  echo "→ Mounting OpenShift ingress CA into Authorino (OIDC JWKS discovery)…"
  "${AUTHORINO_OIDC_CA_SCRIPT}"
else
  echo "Warning: ${AUTHORINO_OIDC_CA_SCRIPT} not found or not executable." >&2
  echo "  Keycloak JWT auth may fail until Authorino trusts the ingress CA." >&2
  echo "  Run: chmod +x infra/scripts/setup-authorino-oidc-ca.sh && ./infra/scripts/setup-authorino-oidc-ca.sh" >&2
fi

#──────────────────────────────────────────────────────────────────────────────
# Gateway + Route for oidc tenant
#──────────────────────────────────────────────────────────────────────────────

oc get namespace "${AITENANT_NAMESPACE}" &>/dev/null || oc create namespace "${AITENANT_NAMESPACE}"

TLS_SECRET_NAME="$(oc get gateway maas-default-gateway -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs[0].name}' 2>/dev/null || true)"
if [[ -z "${TLS_SECRET_NAME}" ]]; then
  TLS_SECRET_NAME="$(oc get gateway maas-default-gateway -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}' 2>/dev/null || true)"
fi
TLS_SECRET_NAME="${TLS_SECRET_NAME:-router-certs-default}"

echo "Creating Gateway ${TENANT_NAME}…"
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${TENANT_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/instance: ${TENANT_NAME}
    app.kubernetes.io/component: gateway
    app.kubernetes.io/part-of: maas-demo-architectures
    opendatahub.io/managed: "false"
    maas.demo/tenant: oidc
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      hostname: ${GATEWAY_HOSTNAME}
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      hostname: ${GATEWAY_HOSTNAME}
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: ${TLS_SECRET_NAME}
EOF

for _ in $(seq 1 30); do
  if oc get gateway "${TENANT_NAME}" -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; then
    break
  fi
  sleep 2
done

if [[ -x "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" ]]; then
  echo "Ensuring oidc (+ default) gateways allow HTTPRoutes from All namespaces…"
  "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" maas-default-gateway "${TENANT_NAME}"
fi

GATEWAY_SERVICE_NAME="${TENANT_NAME}-openshift-default"
oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${TENANT_NAME}-gateway
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/instance: ${TENANT_NAME}
    app.kubernetes.io/part-of: maas-demo-architectures
    gateway.networking.k8s.io/gateway-name: ${TENANT_NAME}
    maas.demo/tenant: oidc
spec:
  host: "${GATEWAY_HOSTNAME}"
  to:
    kind: Service
    name: ${GATEWAY_SERVICE_NAME}
    weight: 100
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

#──────────────────────────────────────────────────────────────────────────────
# AITenant with explicit gateway + External OIDC (manifest: oidc-aitenant.yaml)
#──────────────────────────────────────────────────────────────────────────────

echo "Applying AITenant/${TENANT_NAME} (gateway.name=${TENANT_NAME}, oidc.issuerUrl=${OIDC_ISSUER_URL})…"
# envsubst only replaces OIDC_ISSUER_URL; keep other ${...} out of the YAML
export OIDC_ISSUER_URL
if command -v envsubst >/dev/null 2>&1; then
  envsubst '${OIDC_ISSUER_URL}' < "${DEMO_DIR}/manifests/oidc-aitenant.yaml" | oc apply -f -
else
  # Fallback without gettext
  sed "s|\${OIDC_ISSUER_URL}|${OIDC_ISSUER_URL}|g" "${DEMO_DIR}/manifests/oidc-aitenant.yaml" | oc apply -f -
fi

# Verify OIDC landed on the live object
echo "Verifying AITenant/${TENANT_NAME} spec…"
oc get aitenant "${TENANT_NAME}" -n "${AITENANT_NAMESPACE}" -o jsonpath='{.spec.gateway.name}{"\n"}{.spec.oidc.issuerUrl}{"\n"}{.spec.oidc.clientId}{"\n"}'
if ! oc get aitenant "${TENANT_NAME}" -n "${AITENANT_NAMESPACE}" -o jsonpath='{.spec.oidc.issuerUrl}' | grep -q .; then
  echo "ERROR: spec.oidc.issuerUrl is empty after apply" >&2
  oc get aitenant "${TENANT_NAME}" -n "${AITENANT_NAMESPACE}" -o yaml >&2
  exit 1
fi

echo "Waiting for MaasTenantConfig in ${TENANT_NAMESPACE}…"
for _ in $(seq 1 60); do
  if oc get maastenantconfig default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null \
    || oc get tenant default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null; then
    echo "Tenant config present"
    break
  fi
  sleep 3
done

REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"
if [[ -x "${REPO_ROOT}/infra/scripts/ensure-maasmodelref-tenantref.sh" ]]; then
  echo "Ensuring MaaSModelRef CRD accepts spec.tenantRef…"
  "${REPO_ROOT}/infra/scripts/ensure-maasmodelref-tenantref.sh"
fi

echo "Applying OIDC tenant models + entitlements…"
oc apply -f "${DEMO_DIR}/manifests/oidc-models.yaml"
oc apply -f "${DEMO_DIR}/manifests/oidc-entitlements.yaml"

set +e
oc apply -f "${DEMO_DIR}/manifests/oidc-rolebinding.yaml"
rb_rc=$?
set -e
if [[ "${rb_rc}" -ne 0 ]]; then
  sleep 8
  oc apply -f "${DEMO_DIR}/manifests/oidc-rolebinding.yaml" || \
    echo "Warning: RoleBinding skipped until Role aitenant-oidc-tenant-admin exists."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "OIDC tenant ready (Keycloak via upstream MaaS samples)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Gateway:     https://${GATEWAY_HOSTNAME}"
echo "  Issuer:      ${OIDC_ISSUER_URL}"
echo "  Client ID:   ${OIDC_CLIENT_ID}"
echo "  Models ns:   llm-oidc"
echo "  Entitlements:${TENANT_NAMESPACE} (groups Engineering, Project-Alpha)"
echo ""
echo "Mint a Keycloak token (upstream test user alice_lead / letmein):"
echo "  curl -sk -X POST \\"
echo "    \"https://${KEYCLOAK_HOST}/realms/${OIDC_REALM}/protocol/openid-connect/token\" \\"
echo "    -d grant_type=password -d client_id=${OIDC_CLIENT_ID} \\"
echo "    -d username=alice_lead -d password=letmein | jq -r .access_token"
echo ""
echo "Then mint a MaaS API key with that OIDC bearer:"
echo "  curl -sk -H \"Authorization: Bearer \$OIDC_TOKEN\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"name\":\"demo08-oidc\",\"subscription\":\"demo08-oidc-catalog\",\"expiresIn\":\"30d\"}' \\"
echo "    \"https://${GATEWAY_HOSTNAME}/maas-api/v1/api-keys\""
echo ""
echo "Upstream docs:"
echo "  ${MAAS_REPO:-<MAAS_REPO>}/docs/samples/install/keycloak/README.md"
echo "  https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/advanced-administration/external-oidc.md"
echo ""

#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Bootstrap Demo 08 partner AITenant: dedicated Gateway (+ Route) → AITenant → wait →
# partner models + entitlements. Default tenant resources are applied separately via
# deploy/overlays/demo08 (or this script's --with-default flag).
#
# Usage (from repo root):
#   ./demos/08-maas-35-features/scripts/apply-partner-tenant.sh
#   ./demos/08-maas-35-features/scripts/apply-partner-tenant.sh --with-default
#   ./demos/08-maas-35-features/scripts/apply-partner-tenant.sh partner-maas.apps.example.com
#
set -euo pipefail

TENANT_NAME="partner"
AITENANT_NAMESPACE="ai-tenants"
GATEWAY_NAMESPACE="openshift-ingress"
TENANT_NAMESPACE="ai-tenant-${TENANT_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEMO_DIR}/../.." && pwd)"
WITH_DEFAULT=false
GATEWAY_HOSTNAME="${1:-}"

if [[ "${1:-}" == "--with-default" ]]; then
  WITH_DEFAULT=true
  GATEWAY_HOSTNAME="${2:-}"
elif [[ "${2:-}" == "--with-default" ]]; then
  WITH_DEFAULT=true
fi

if [[ -z "${GATEWAY_HOSTNAME}" ]]; then
  CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -z "${CLUSTER_DOMAIN}" ]]; then
    echo "Error: could not detect cluster domain; pass hostname: $0 <tenant-hostname>" >&2
    exit 1
  fi
  GATEWAY_HOSTNAME="${TENANT_NAME}-maas.${CLUSTER_DOMAIN}"
  echo "Auto-detected gateway hostname: ${GATEWAY_HOSTNAME}"
fi

TLS_SECRET_NAME="$(oc get gateway maas-default-gateway -n "${GATEWAY_NAMESPACE}" \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].tls.certificateRefs[0].name}' 2>/dev/null || true)"
if [[ -z "${TLS_SECRET_NAME}" ]]; then
  TLS_SECRET_NAME="$(oc get gateway maas-default-gateway -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.spec.listeners[0].tls.certificateRefs[0].name}' 2>/dev/null || true)"
fi
if [[ -z "${TLS_SECRET_NAME}" ]]; then
  TLS_SECRET_NAME="router-certs-default"
  echo "Warning: using default TLS secret ${TLS_SECRET_NAME}"
fi

oc get namespace "${AITENANT_NAMESPACE}" &>/dev/null || oc create namespace "${AITENANT_NAMESPACE}"

if [[ "${WITH_DEFAULT}" == "true" ]]; then
  echo "Applying default-tenant Demo 08 overlay (simulators + granite/llm-katan entitlements)…"
  oc kustomize --load-restrictor LoadRestrictionsNone "${REPO_ROOT}/deploy/overlays/demo08" | oc apply -f -
  oc apply -f "${DEMO_DIR}/manifests/required-groups.yaml"
fi

echo "Creating Gateway ${TENANT_NAME} in ${GATEWAY_NAMESPACE}…"
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
    maas.demo/tenant: partner
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

echo "Waiting for Gateway Accepted…"
for _ in $(seq 1 30); do
  if oc get gateway "${TENANT_NAME}" -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null | grep -q True; then
    echo "Gateway Accepted"
    break
  fi
  sleep 2
done

if [[ -x "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" ]]; then
  echo "Ensuring partner (+ default) gateways allow HTTPRoutes from All namespaces…"
  "${REPO_ROOT}/infra/scripts/ensure-gateway-allowed-routes.sh" maas-default-gateway "${TENANT_NAME}"
fi

GATEWAY_SERVICE_NAME="${TENANT_NAME}-openshift-default"
echo "Creating Route ${TENANT_NAME}-gateway…"
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
    maas.demo/tenant: partner
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

echo "Applying AITenant ${TENANT_NAME} (explicit spec.gateway.name=${TENANT_NAME})…"
oc apply -f "${DEMO_DIR}/manifests/partner-aitenant.yaml"
oc get aitenant "${TENANT_NAME}" -n "${AITENANT_NAMESPACE}" -o jsonpath='gateway={.spec.gateway.name}{"\n"}'

echo "Waiting for MaasTenantConfig in ${TENANT_NAMESPACE}…"
for _ in $(seq 1 60); do
  if oc get maastenantconfig default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null; then
    echo "MaasTenantConfig present"
    break
  fi
  # legacy Tenant CR name during migration
  if oc get tenant default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null; then
    echo "Tenant CR present (legacy name)"
    break
  fi
  sleep 3
done

if ! oc get maastenantconfig default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null \
  && ! oc get tenant default-tenant -n "${TENANT_NAMESPACE}" &>/dev/null; then
  echo "Warning: MaasTenantConfig not ready yet — entitlements may be rejected until the controller finishes." >&2
  echo "  oc get aitenant ${TENANT_NAME} -n ${AITENANT_NAMESPACE} -o yaml" >&2
fi

echo "Applying partner models (mistral → ai-tenant-partner; llama → llm-partner)…"
if [[ -x "${REPO_ROOT}/infra/scripts/ensure-maasmodelref-tenantref.sh" ]]; then
  echo "Ensuring MaaSModelRef CRD accepts spec.tenantRef…"
  "${REPO_ROOT}/infra/scripts/ensure-maasmodelref-tenantref.sh"
fi
oc apply -f "${DEMO_DIR}/manifests/partner-models.yaml"

# Namespace move: drop stale mistral copies left in llm-partner from older layouts.
if oc get maasmodelref partner-mistral-7b -n llm-partner &>/dev/null; then
  echo "Removing stale MaaSModelRef partner-mistral-7b from llm-partner…"
  oc delete maasmodelref partner-mistral-7b -n llm-partner --wait=false || true
fi
if oc get llminferenceservice partner-mistral-7b -n llm-partner &>/dev/null; then
  echo "Removing stale LLMInferenceService partner-mistral-7b from llm-partner…"
  oc delete llminferenceservice partner-mistral-7b -n llm-partner --wait=false || true
fi

echo "Applying partner entitlements (ai-tenant-partner)…"
oc apply -f "${DEMO_DIR}/manifests/required-groups.yaml"
oc apply -f "${DEMO_DIR}/manifests/partner-entitlements.yaml"

echo "Applying partner tenant-admin RoleBinding (retry if Role not ready)…"
set +e
oc apply -f "${DEMO_DIR}/manifests/partner-rolebinding.yaml"
rb_rc=$?
set -e
if [[ "${rb_rc}" -ne 0 ]]; then
  echo "Retrying RoleBinding in 8s…"
  sleep 8
  oc apply -f "${DEMO_DIR}/manifests/partner-rolebinding.yaml" || \
    echo "Warning: RoleBinding skipped — create later when Role aitenant-partner-tenant-admin exists."
fi

echo ""
echo "Partner tenant bootstrap complete."
echo "  Gateway host:   https://${GATEWAY_HOSTNAME}"
echo "  Tenant ns:      ${TENANT_NAMESPACE}"
echo "  Models:         partner-mistral-7b (ai-tenant-partner), partner-llama-3-1-8b (llm-partner)"
echo "  Subscription:   demo08-partner-catalog"
echo ""
echo "Verify:"
echo "  oc get aitenant ${TENANT_NAME} -n ${AITENANT_NAMESPACE}"
echo "  oc get maasmodelref -n ${TENANT_NAMESPACE} -n llm-partner"
echo "  oc get maassubscription,maasauthpolicy -n ${TENANT_NAMESPACE}"
echo ""
echo "As bob, mint a key against the partner gateway:"
echo "  curl -sS -H \"Authorization: Bearer \$(oc whoami -t)\" -H 'Content-Type: application/json' \\"
echo "    -d '{\"name\":\"demo08-bob\",\"subscription\":\"demo08-partner-catalog\",\"expiresIn\":\"30d\"}' \\"
echo "    \"https://${GATEWAY_HOSTNAME}/maas-api/v1/api-keys\""

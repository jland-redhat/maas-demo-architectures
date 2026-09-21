#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Create maas-default-gateway for Models-as-a-Service (lab-oriented).
# Logic mirrors upstream scripts/setup-gateway.sh (route mode by default):
#   https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-gateway.sh
#
# For full clusterip/disconnected support, prefer upstream:
#   MAAS_REPO=/path/to/models-as-a-service "${MAAS_REPO}/scripts/setup-gateway.sh"
#
# Environment:
#   INGRESS_MODE     route (default) | clusterip
#   CLUSTER_DOMAIN   override apps domain
#   CERT_NAME        TLS secret in openshift-ingress (route mode)
#   DRY_RUN          true | false
#
# Usage (from repo root):
#   ./infra/scripts/setup-gateway.sh
#   INGRESS_MODE=clusterip ./infra/scripts/setup-gateway.sh
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

INGRESS_MODE="${INGRESS_MODE:-route}"
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-}"
CERT_NAME="${CERT_NAME:-}"
DRY_RUN="${DRY_RUN:-false}"

GATEWAY_NAMESPACE="openshift-ingress"
GATEWAY_NAME="maas-default-gateway"
GATEWAYCLASS_NAME="openshift-default"
GW_OPTIONS_CONFIGMAP="gw-options"
GATEWAY_ROUTE_NAME="maas-gateway-route"
SERVICE_CA_SECRET="maas-gw-service-tls"
GATEWAY_SERVICE_NAME="${GATEWAY_NAME}-${GATEWAYCLASS_NAME}"
GATEWAY_TIMEOUT="${CUSTOM_CHECK_TIMEOUT:-120}"

log_info()  { echo "ℹ  $*"; }
log_warn()  { echo "⚠  $*" >&2; }
log_error() { echo "✗  $*" >&2; }

create_tls_secret() {
  local name="$1" namespace="$2" cn="$3"
  if ${OC} get secret "${name}" -n "${namespace}" &>/dev/null; then
    log_info "TLS secret ${name} already exists in ${namespace}"
    return 0
  fi
  local temp_dir
  temp_dir="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${temp_dir}/tls.key" \
    -out "${temp_dir}/tls.crt" \
    -days 365 -nodes \
    -subj "/CN=${cn}" 2>/dev/null
  ${OC} create secret tls "${name}" \
    --cert="${temp_dir}/tls.crt" \
    --key="${temp_dir}/tls.key" \
    -n "${namespace}"
  rm -rf "${temp_dir}"
}

detect_cluster_domain() {
  if [[ -n "${CLUSTER_DOMAIN}" ]]; then
    log_info "Using provided cluster domain: ${CLUSTER_DOMAIN}"
    return 0
  fi
  CLUSTER_DOMAIN="$(${OC} get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -z "${CLUSTER_DOMAIN}" ]]; then
    log_error "Could not determine cluster domain; set CLUSTER_DOMAIN"
    exit 1
  fi
  log_info "Detected cluster domain: ${CLUSTER_DOMAIN}"
}

detect_tls_certificate() {
  if [[ -n "${CERT_NAME}" ]]; then
    log_info "Using provided TLS certificate: ${CERT_NAME}"
    return 0
  fi
  log_info "Detecting TLS certificate secret…"

  CERT_NAME="$(${OC} get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)"
  if [[ -n "${CERT_NAME}" ]] && ${OC} get secret -n "${GATEWAY_NAMESPACE}" "${CERT_NAME}" &>/dev/null; then
    log_info "  Found certificate from IngressController: ${CERT_NAME}"
    return 0
  fi
  CERT_NAME=""

  CERT_NAME="$(${OC} get deployment router-default -n "${GATEWAY_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.volumes[?(@.name=="default-certificate")].secret.secretName}' 2>/dev/null || true)"
  if [[ -n "${CERT_NAME}" ]] && ${OC} get secret -n "${GATEWAY_NAMESPACE}" "${CERT_NAME}" &>/dev/null; then
    log_info "  Found certificate from router deployment: ${CERT_NAME}"
    return 0
  fi
  CERT_NAME=""

  for cert in default-gateway-cert router-certs-default; do
    if ${OC} get secret -n "${GATEWAY_NAMESPACE}" "${cert}" &>/dev/null; then
      CERT_NAME="${cert}"
      log_info "  Found TLS certificate secret: ${CERT_NAME}"
      return 0
    fi
  done

  log_warn "  No TLS certificate found. Creating self-signed certificate…"
  local gateway_hostname="maas.${CLUSTER_DOMAIN}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    CERT_NAME="maas-gateway-tls"
    return 0
  fi
  create_tls_secret "maas-gateway-tls" "${GATEWAY_NAMESPACE}" "${gateway_hostname}"
  CERT_NAME="maas-gateway-tls"
}

setup_gatewayclass() {
  if ${OC} get gatewayclass "${GATEWAYCLASS_NAME}" &>/dev/null; then
    log_info "GatewayClass ${GATEWAYCLASS_NAME} already exists"
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would create GatewayClass ${GATEWAYCLASS_NAME}"
    return 0
  fi
  log_info "Creating GatewayClass ${GATEWAYCLASS_NAME}…"
  ${OC} apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ${GATEWAYCLASS_NAME}
spec:
  controllerName: "openshift.io/gateway-controller/v1"
EOF
}

apply_route_gateway() {
  detect_tls_certificate
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would create Gateway ${GATEWAY_NAME} (cert=${CERT_NAME})"
    return 0
  fi
  log_info "Applying Gateway ${GATEWAY_NAME} (hostname=maas.${CLUSTER_DOMAIN}, cert=${CERT_NAME})…"
  ${OC} apply --server-side=true -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/instance: ${GATEWAY_NAME}
    app.kubernetes.io/component: gateway
    app.kubernetes.io/part-of: maas-demo-architectures
    opendatahub.io/managed: "false"
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: ${GATEWAYCLASS_NAME}
  listeners:
    - name: https
      hostname: maas.${CLUSTER_DOMAIN}
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
            name: ${CERT_NAME}
EOF

  log_info "Waiting for Gateway Programmed (timeout ${GATEWAY_TIMEOUT}s)…"
  if ! ${OC} wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" \
    -n "${GATEWAY_NAMESPACE}" --timeout="${GATEWAY_TIMEOUT}s" 2>/dev/null; then
    log_warn "Gateway not Programmed after ${GATEWAY_TIMEOUT}s — check OSSM / GatewayClass"
  else
    log_info "Gateway is Programmed"
  fi
}

apply_clusterip_gateway() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY RUN] Would create clusterip Gateway + Route"
    return 0
  fi

  if ! ${OC} get configmap "${GW_OPTIONS_CONFIGMAP}" -n "${GATEWAY_NAMESPACE}" &>/dev/null; then
    log_info "Creating ConfigMap ${GW_OPTIONS_CONFIGMAP}…"
    ${OC} apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${GW_OPTIONS_CONFIGMAP}
  namespace: ${GATEWAY_NAMESPACE}
data:
  service: |
    metadata:
      annotations:
        service.beta.openshift.io/serving-cert-secret-name: "${SERVICE_CA_SECRET}"
    spec:
      type: ClusterIP
EOF
  fi

  log_info "Applying ClusterIP Gateway ${GATEWAY_NAME}…"
  ${OC} apply --server-side=true -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: maas
    app.kubernetes.io/instance: ${GATEWAY_NAME}
    app.kubernetes.io/component: gateway
    app.kubernetes.io/part-of: maas-demo-architectures
    opendatahub.io/managed: "false"
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
spec:
  gatewayClassName: ${GATEWAYCLASS_NAME}
  infrastructure:
    parametersRef:
      group: ""
      kind: ConfigMap
      name: ${GW_OPTIONS_CONFIGMAP}
  listeners:
    - name: https
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
            name: ${SERVICE_CA_SECRET}
EOF

  ${OC} wait --for=condition=Programmed "gateway/${GATEWAY_NAME}" \
    -n "${GATEWAY_NAMESPACE}" --timeout="${GATEWAY_TIMEOUT}s"

  local hostname="maas.${CLUSTER_DOMAIN}"
  log_info "Creating Route ${GATEWAY_ROUTE_NAME} → ${hostname}…"
  ${OC} apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${GATEWAY_ROUTE_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    gateway.networking.k8s.io/gateway-name: ${GATEWAY_NAME}
    app.kubernetes.io/part-of: maas-demo-architectures
spec:
  host: ${hostname}
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
}

#── main ──────────────────────────────────────────────────────────────────────

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  MaaS default Gateway (maas-default-gateway)                    ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

if [[ ! "${INGRESS_MODE}" =~ ^(route|clusterip)$ ]]; then
  log_error "INGRESS_MODE must be route or clusterip (got: ${INGRESS_MODE})"
  exit 1
fi

detect_cluster_domain
setup_gatewayclass

case "${INGRESS_MODE}" in
  route)     apply_route_gateway ;;
  clusterip) apply_clusterip_gateway ;;
esac

# AIGateway may narrow allowedRoutes after apply; re-assert from All for model ns routes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/ensure-gateway-allowed-routes.sh" ]]; then
  GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE}" \
    "${SCRIPT_DIR}/ensure-gateway-allowed-routes.sh" "${GATEWAY_NAME}"
fi

echo ""
echo "✅ Gateway setup finished"
echo "  Name:     ${GATEWAY_NAMESPACE}/${GATEWAY_NAME}"
echo "  Hostname: https://maas.${CLUSTER_DOMAIN}"
echo "  Mode:     ${INGRESS_MODE}"

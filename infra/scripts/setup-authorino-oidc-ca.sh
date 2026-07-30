#!/usr/bin/env bash
#
# Mount the OpenShift ingress CA into Authorino so External OIDC (Keycloak)
# JWT validation can fetch OIDC discovery / JWKS over the cluster apps route.
#
# Without this, Authorino fails with:
#   tls: failed to verify certificate: x509: certificate signed by unknown authority
# when issuerUrl is https://keycloak.<apps-domain>/realms/...
#
# Builds a combined CA bundle (service-ca + ingress CA), mounts it on the
# Authorino deployment, and points SSL_CERT_FILE / REQUESTS_CA_BUNDLE at it.
# That preserves maas-api (service-ca) trust from setup-authorino-tls.sh while
# adding trust for ingress-terminated routes (Keycloak).
#
# Pattern adapted from upstream MaaS e2e (EXTERNAL_OIDC path in
# test/e2e/scripts/prow_run_smoke_test.sh), with stronger CA discovery for
# clusters that use the default IngressController certificate (router-ca).
#
# Environment variables:
#   AUTHORINO_NAMESPACE  Authorino namespace (auto-detected if unset)
#   OC                   oc/kubectl binary (auto-detected if unset)
#
# Usage (from repo root):
#   ./infra/scripts/setup-authorino-oidc-ca.sh
#   AUTHORINO_NAMESPACE=kuadrant-system ./infra/scripts/setup-authorino-oidc-ca.sh
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
  echo "kuadrant-system"
}

extract_ingress_ca() {
  # Writes PEM CA material to $1. Prefer a true CA over a leaf cert.
  local out="$1"
  local tmp ingress_cert_name

  # 1) Ingress operator router-ca (default OpenShift apps wildcard signer)
  if ${OC} get secret router-ca -n openshift-ingress-operator &>/dev/null; then
    if ${OC} get secret router-ca -n openshift-ingress-operator \
      -o jsonpath='{.data.tls\.crt}' | base64 -d >"${out}" 2>/dev/null \
      && [[ -s "${out}" ]]; then
      echo "router-ca (openshift-ingress-operator)"
      return 0
    fi
  fi

  # 2) Managed default-ingress-cert bundle (leaf + CA)
  if ${OC} get configmap default-ingress-cert -n openshift-config-managed &>/dev/null; then
    if ${OC} get configmap default-ingress-cert -n openshift-config-managed \
      -o jsonpath='{.data.ca-bundle\.crt}' >"${out}" 2>/dev/null \
      && [[ -s "${out}" ]]; then
      echo "default-ingress-cert (openshift-config-managed)"
      return 0
    fi
  fi

  # 3) Custom IngressController defaultCertificate (upstream e2e path)
  ingress_cert_name="$(${OC} get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)"
  if [[ -n "${ingress_cert_name}" ]]; then
    tmp="$(mktemp)"
    if ${OC} get secret "${ingress_cert_name}" -n openshift-ingress \
      -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"${tmp}" \
      && [[ -s "${tmp}" ]]; then
      mv "${tmp}" "${out}"
      echo "IngressController defaultCertificate ca.crt (${ingress_cert_name})"
      return 0
    fi
    if ${OC} get secret "${ingress_cert_name}" -n openshift-ingress \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >"${tmp}" \
      && [[ -s "${tmp}" ]]; then
      mv "${tmp}" "${out}"
      echo "IngressController defaultCertificate tls.crt (${ingress_cert_name})"
      return 0
    fi
    rm -f "${tmp}"
  fi

  return 1
}

NAMESPACE="$(detect_authorino_namespace)"
VOLUME_NAME="authorino-trusted-ca"
MOUNT_PATH="/etc/ssl/certs/authorino-ca-bundle"
BUNDLE_FILE="${MOUNT_PATH}/ca-bundle.crt"
CM_NAME="authorino-trusted-ca-bundle"

echo "Configuring Authorino OIDC/ingress CA trust in namespace: ${NAMESPACE}"

if ! ${OC} get deployment authorino -n "${NAMESPACE}" &>/dev/null; then
  echo "ERROR: deployment/authorino not found in ${NAMESPACE}" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

INGRESS_CA="${WORKDIR}/ingress-ca.pem"
SERVICE_CA="${WORKDIR}/service-ca.pem"
COMBINED="${WORKDIR}/ca-bundle.crt"

echo "→ Discovering OpenShift ingress CA…"
if ! CA_SOURCE="$(extract_ingress_ca "${INGRESS_CA}")"; then
  echo "ERROR: could not find an ingress CA (router-ca / default-ingress-cert / defaultCertificate)" >&2
  echo "  Authorino will fail Keycloak OIDC discovery with x509 unknown authority." >&2
  exit 1
fi
echo "  Using: ${CA_SOURCE}"

# Prefer namespaced service-ca injection ConfigMap; fall back to cluster service-ca
if ${OC} get configmap openshift-service-ca.crt -n "${NAMESPACE}" \
  -o jsonpath='{.data.service-ca\.crt}' >"${SERVICE_CA}" 2>/dev/null \
  && [[ -s "${SERVICE_CA}" ]]; then
  echo "  Including service-ca from ${NAMESPACE}/openshift-service-ca.crt"
elif ${OC} get configmap openshift-service-ca.crt -n openshift-config-managed \
  -o jsonpath='{.data.service-ca\.crt}' >"${SERVICE_CA}" 2>/dev/null \
  && [[ -s "${SERVICE_CA}" ]]; then
  echo "  Including service-ca from openshift-config-managed/openshift-service-ca.crt"
else
  echo "  Warning: service-ca not found; bundle will contain ingress CA only"
  : >"${SERVICE_CA}"
fi

{
  if [[ -s "${SERVICE_CA}" ]]; then
    cat "${SERVICE_CA}"
    echo
  fi
  cat "${INGRESS_CA}"
  echo
} >"${COMBINED}"

echo "→ Creating ConfigMap ${CM_NAME}…"
${OC} create configmap "${CM_NAME}" -n "${NAMESPACE}" \
  --from-file=ca-bundle.crt="${COMBINED}" \
  --dry-run=client -o yaml | ${OC} apply -f -

# Keep a copy named like the upstream e2e ConfigMap for operators/docs that look for it
${OC} create configmap authorino-oidc-ca -n "${NAMESPACE}" \
  --from-file=ca.crt="${INGRESS_CA}" \
  --dry-run=client -o yaml | ${OC} apply -f -

echo "→ Ensuring volume mount on deployment/authorino…"
EXISTING_VOLUMES="$(${OC} get deployment authorino -n "${NAMESPACE}" \
  -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null || true)"
if [[ " ${EXISTING_VOLUMES} " != *" ${VOLUME_NAME} "* ]]; then
  ${OC} patch deployment authorino -n "${NAMESPACE}" --type=json -p "[
    {\"op\": \"add\", \"path\": \"/spec/template/spec/volumes/-\", \"value\": {
      \"name\": \"${VOLUME_NAME}\",
      \"configMap\": {\"name\": \"${CM_NAME}\"}
    }},
    {\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/volumeMounts/-\", \"value\": {
      \"name\": \"${VOLUME_NAME}\",
      \"mountPath\": \"${MOUNT_PATH}\",
      \"readOnly\": true
    }}
  ]"
else
  echo "  Volume ${VOLUME_NAME} already present (ConfigMap content refreshed)"
fi

echo "→ Pointing SSL_CERT_FILE at combined CA bundle…"
${OC} -n "${NAMESPACE}" set env deployment/authorino \
  "SSL_CERT_FILE=${BUNDLE_FILE}" \
  "REQUESTS_CA_BUNDLE=${BUNDLE_FILE}"

echo "→ Waiting for Authorino rollout…"
${OC} rollout status deployment/authorino -n "${NAMESPACE}" --timeout=180s

echo ""
echo "Authorino OIDC/ingress CA trust configured"
echo "  ConfigMap: ${NAMESPACE}/${CM_NAME}"
echo "  SSL_CERT_FILE=${BUNDLE_FILE}"
echo "  Ingress CA source: ${CA_SOURCE}"
echo ""
echo "  Re-run after Authorino operator reconciles away the deployment patch if OIDC 401s return."

#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# =============================================================================
# HACK — NOT part of official install (see infra/hacks/README.md)
# =============================================================================
#
# Symptom
#   Perses CrashLoopBackOff:
#     flag provided but not defined: -web.tls-min-version
#   — or —
#   PersesDashboard conversion webhook fails / Dashboard observability stuck
#   because perses-operator has no endpoints (scaled to 0).
#
# Cause
#   COO perses-operator (--tls-configure-operands) injects --web.tls-* CLI flags
#   that some RHOAI-pinned Perses images do not accept.
#
#   An older demo "keeper" Deployment (perses-tls-workaround) fought that by
#   keeping perses-operator at replicas=0 forever. That breaks CRD conversion
#   webhooks (perses-operator-service has no backends) and must not be the
#   normal install path.
#
# Prefer (product)
#   Align RELATED_IMAGE_PERSES_IMAGE with a Perses build that supports the TLS
#   flags, or drop --tls-configure-operands from perses-operator — then leave
#   the operator Running.
#
# This hack
#   cleanup     Remove keeper + restore perses-operator (default if no args)
#   strip-args  One-shot: strip unsupported TLS args from Perses STS only
#               (do NOT scale the operator to 0)
#
# Usage (from repo root):
#   ./infra/hacks/perses-tls-skew.hack.sh cleanup
#   ./infra/hacks/perses-tls-skew.hack.sh strip-args
#   MONITORING_NS=opendatahub ./infra/hacks/perses-tls-skew.hack.sh cleanup
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

COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
MONITORING_NS="${MONITORING_NS:-}"
if [[ -z "${MONITORING_NS}" ]]; then
  if ${OC} get namespace redhat-ods-monitoring &>/dev/null; then
    MONITORING_NS=redhat-ods-monitoring
  elif ${OC} get namespace opendatahub &>/dev/null; then
    MONITORING_NS=opendatahub
  else
    MONITORING_NS=redhat-ods-monitoring
  fi
fi

ACTION="${1:-cleanup}"

strip_perses_tls_args() {
  local sts_name
  while IFS= read -r sts_name; do
    [[ -z "${sts_name}" ]] && continue
    local args
    args="$(${OC} get sts "${sts_name}" -n "${MONITORING_NS}" \
      -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null || true)"
    if echo "${args}" | grep -qE 'web\.tls-min-version|web\.tls-cipher-suites'; then
      echo "Stripping unsupported TLS CLI flags from sts/${sts_name}…"
      ${OC} patch sts "${sts_name}" -n "${MONITORING_NS}" --type=json -p \
        '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--config=/etc/perses/config/config.yaml","--web.listen-address=:8080"]}]'
      ${OC} delete pod -n "${MONITORING_NS}" -l app.kubernetes.io/name=perses --wait=false 2>/dev/null || true
    else
      echo "sts/${sts_name}: no unsupported TLS flags"
    fi
  done < <(${OC} get sts -n "${MONITORING_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i perses || true)
}

cleanup_keeper_and_restore_operator() {
  echo "Monitoring ns: ${MONITORING_NS}"
  echo "COO ns:         ${COO_NS}"
  echo ""

  if ${OC} get deploy perses-tls-workaround -n "${MONITORING_NS}" &>/dev/null; then
    echo "Removing perses-tls-workaround (scales operator to 0 — breaks conversion webhooks)…"
    ${OC} delete deploy,sa,role,rolebinding -n "${MONITORING_NS}" \
      -l app.kubernetes.io/name=perses-tls-workaround --ignore-not-found
  else
    echo "No perses-tls-workaround Deployment in ${MONITORING_NS}"
  fi

  # COO-side RBAC created by the old manifest
  ${OC} delete role,rolebinding -n "${COO_NS}" perses-tls-workaround-coo --ignore-not-found 2>/dev/null || true

  if ${OC} get deploy perses-operator -n "${COO_NS}" &>/dev/null; then
    echo "Scaling perses-operator to 1…"
    ${OC} scale deploy/perses-operator -n "${COO_NS}" --replicas=1
    ${OC} rollout status deploy/perses-operator -n "${COO_NS}" --timeout=120s || true
  else
    echo "perses-operator Deployment not found in ${COO_NS}"
  fi

  echo ""
  echo "Webhook endpoints (should list an address):"
  ${OC} get endpoints perses-operator-service -n "${COO_NS}" 2>/dev/null || \
    ${OC} get endpoints -n "${COO_NS}" | grep -i perses || true

  echo ""
  echo "If Perses CrashLoops again on --web.tls-*, run:"
  echo "  $0 strip-args"
  echo "Do NOT re-scale the operator to 0."
}

case "${ACTION}" in
  cleanup|remove|restore)
    cleanup_keeper_and_restore_operator
    ;;
  strip-args|strip)
    strip_perses_tls_args
    ;;
  --help|-h|help)
    sed -n '2,45p' "$0"
    ;;
  *)
    echo "Usage: $0 {cleanup|strip-args}" >&2
    exit 1
    ;;
esac

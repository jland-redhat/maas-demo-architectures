#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Configure ODH/RHOAI monitoring so Showback/FinOps works:
#   MonitoringStackAvailable=False: MetricsNotConfigured
# is fixed by setting DSCI spec.monitoring.metrics.storage (empty metrics: {} is not enough).
#
# Steps:
#   1. Install Cluster Observability Operator (COO) + OpenTelemetry Operator
#   2. Repair stuck OpenTelemetry CSV when CRDs are missing
#   3. Patch DSCInitialization metrics.storage
#   4. Enable User Workload Monitoring (safe merge)
#   5. Enable Kuadrant observability (limitador metrics)
#   6. Enable observabilityDashboard on OdhDashboardConfig
#   7. Perses NetworkPolicy so the AI Dashboard can reach Perses
#
# Perses TLS / operator-skew workarounds are NOT applied here — see
#   infra/hacks/perses-tls-skew.hack.sh
#
# Usage (from repo root):
#   ./infra/scripts/setup-observability.sh
#   SKIP_OPERATORS=1 ./infra/scripts/setup-observability.sh
#   METRICS_SIZE=10Gi METRICS_RETENTION=30d ./infra/scripts/setup-observability.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OBS_DIR="${INFRA_DIR}/observability"

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

SKIP_OPERATORS="${SKIP_OPERATORS:-0}"
SKIP_UWM="${SKIP_UWM:-0}"
SKIP_KUADRANT_OBS="${SKIP_KUADRANT_OBS:-0}"
SKIP_DASHBOARD_FLAG="${SKIP_DASHBOARD_FLAG:-0}"
METRICS_SIZE="${METRICS_SIZE:-5Gi}"
METRICS_RETENTION="${METRICS_RETENTION:-15d}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
OTEL_NS="${OTEL_NS:-openshift-operators}"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"

log_info()  { echo "ℹ  $*"; }
log_warn()  { echo "⚠  $*" >&2; }
log_error() { echo "✗  $*" >&2; }

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  Observability — DSCI metrics + Showback/FinOps prerequisites   ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""

#── discover DSCI ──────────────────────────────────────────────────────────────

DSCI_NAME="${DSCI_NAME:-}"
if [[ -z "${DSCI_NAME}" ]]; then
  DSCI_NAME="$(${OC} get dscinitialization -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
if [[ -z "${DSCI_NAME}" ]]; then
  log_error "No DSCInitialization found. Install ODH/RHOAI first."
  exit 1
fi

MONITORING_NS="$(${OC} get dscinitialization "${DSCI_NAME}" \
  -o jsonpath='{.spec.monitoring.namespace}' 2>/dev/null || true)"
APPS_NS="$(${OC} get dscinitialization "${DSCI_NAME}" \
  -o jsonpath='{.spec.applicationsNamespace}' 2>/dev/null || true)"

# Defaults if fields empty
if [[ -z "${MONITORING_NS}" ]]; then
  if ${OC} get namespace redhat-ods-monitoring &>/dev/null; then
    MONITORING_NS="redhat-ods-monitoring"
  else
    MONITORING_NS="opendatahub"
  fi
fi
if [[ -z "${APPS_NS}" ]]; then
  if ${OC} get namespace redhat-ods-applications &>/dev/null; then
    APPS_NS="redhat-ods-applications"
  else
    APPS_NS="opendatahub"
  fi
fi

log_info "DSCI:              ${DSCI_NAME}"
log_info "Monitoring NS:     ${MONITORING_NS}"
log_info "Applications NS:   ${APPS_NS}"
log_info "Metrics storage:   size=${METRICS_SIZE} retention=${METRICS_RETENTION}"
echo ""

#── 1. Operators ───────────────────────────────────────────────────────────────

wait_for_crd() {
  local crd="$1"
  local timeout="${2:-300}"
  local elapsed=0
  log_info "Waiting for CRD ${crd}…"
  while (( elapsed < timeout )); do
    if ${OC} get crd "${crd}" &>/dev/null; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

repair_opentelemetry_operator() {
  # OLM can leave the OTEL CSV in Pending/RequirementsNotMet with the controller
  # Deployment running but CRDs deleted/missing — Monitoring then stays Not Ready
  # (OpenTelemetryCollectorCRDNotFoundReason) and Perses collectors never appear.
  if ${OC} get crd opentelemetrycollectors.opentelemetry.io &>/dev/null; then
    return 0
  fi
  log_warn "OpenTelemetryCollector CRD missing — repairing opentelemetry-product Subscription"
  local csv
  csv="$(${OC} get sub opentelemetry-product -n "${OTEL_NS}" \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
  local ip
  ip="$(${OC} get sub opentelemetry-product -n "${OTEL_NS}" \
    -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)"
  [[ -n "${csv}" ]] && ${OC} delete csv "${csv}" -n "${OTEL_NS}" --wait=false 2>/dev/null || true
  [[ -n "${ip}" ]] && ${OC} delete installplan "${ip}" -n "${OTEL_NS}" --wait=false 2>/dev/null || true
  ${OC} delete sub opentelemetry-product -n "${OTEL_NS}" --wait=true 2>/dev/null || true
  ${OC} apply -f "${OBS_DIR}/opentelemetry-operator.yaml"
}

if [[ "${SKIP_OPERATORS}" != "1" ]]; then
  log_info "Installing Cluster Observability Operator…"
  ${OC} apply -f "${OBS_DIR}/cluster-observability-operator.yaml"

  log_info "Installing OpenTelemetry Operator…"
  ${OC} apply -f "${OBS_DIR}/opentelemetry-operator.yaml"
  repair_opentelemetry_operator

  wait_for_crd monitoringstacks.monitoring.rhobs 300 || \
    log_warn "monitoringstacks.monitoring.rhobs CRD not ready yet (COO still installing)"
  if ! wait_for_crd opentelemetrycollectors.opentelemetry.io 300; then
    log_warn "opentelemetrycollectors.opentelemetry.io CRD not ready — retrying OTEL repair"
    repair_opentelemetry_operator
    wait_for_crd opentelemetrycollectors.opentelemetry.io 300 || \
      log_warn "OpenTelemetry CRDs still missing; Monitoring Ready may stay False"
  fi
else
  log_info "Skipping operator install (SKIP_OPERATORS=1)"
  repair_opentelemetry_operator || true
fi

#── 2. DSCI metrics.storage patch ──────────────────────────────────────────────

log_info "Patching DSCI ${DSCI_NAME} monitoring.metrics.storage…"
${OC} patch dscinitialization "${DSCI_NAME}" --type=merge -p "{
  \"spec\": {
    \"monitoring\": {
      \"managementState\": \"Managed\",
      \"namespace\": \"${MONITORING_NS}\",
      \"metrics\": {
        \"storage\": {
          \"size\": \"${METRICS_SIZE}\",
          \"retention\": \"${METRICS_RETENTION}\"
        }
      }
    }
  }
}"

#── 3. User Workload Monitoring ────────────────────────────────────────────────

if [[ "${SKIP_UWM}" != "1" ]]; then
  log_info "Ensuring User Workload Monitoring is enabled…"
  if ${OC} get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
    existing="$(${OC} get configmap cluster-monitoring-config -n openshift-monitoring \
      -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
    if echo "${existing}" | grep -q 'enableUserWorkload:\s*true'; then
      log_info "  enableUserWorkload already true"
    else
      # Merge carefully: append if missing
      tmp="$(mktemp)"
      printf '%s\n' "${existing}" > "${tmp}"
      if ! grep -q 'enableUserWorkload' "${tmp}"; then
        printf '\nenableUserWorkload: true\n' >> "${tmp}"
      else
        # flip false → true
        sed -i 's/enableUserWorkload:.*/enableUserWorkload: true/' "${tmp}"
      fi
      ${OC} create configmap cluster-monitoring-config \
        --from-file=config.yaml="${tmp}" \
        -n openshift-monitoring --dry-run=client -o yaml | ${OC} apply -f -
      rm -f "${tmp}"
      log_info "  Updated cluster-monitoring-config"
    fi
  else
    ${OC} apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
  labels:
    app.kubernetes.io/part-of: maas-demo-architectures
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    log_info "  Created cluster-monitoring-config"
  fi
else
  log_info "Skipping UWM (SKIP_UWM=1)"
fi

#── 4. Kuadrant observability ──────────────────────────────────────────────────

if [[ "${SKIP_KUADRANT_OBS}" != "1" ]]; then
  kuadrant_ns=""
  for ns in rh-connectivity-link kuadrant-system; do
    if ${OC} get kuadrant kuadrant -n "${ns}" &>/dev/null; then
      kuadrant_ns="${ns}"
      break
    fi
  done
  if [[ -n "${kuadrant_ns}" ]]; then
    log_info "Enabling Kuadrant observability in ${kuadrant_ns}…"
    ${OC} patch kuadrant kuadrant -n "${kuadrant_ns}" --type=merge \
      -p '{"spec":{"observability":{"enable":true}}}' || \
      log_warn "Could not patch Kuadrant observability (non-fatal)"
  else
    log_warn "No Kuadrant CR found — skip observability patch"
  fi
else
  log_info "Skipping Kuadrant observability (SKIP_KUADRANT_OBS=1)"
fi

#── 5. Dashboard flag ──────────────────────────────────────────────────────────

if [[ "${SKIP_DASHBOARD_FLAG}" != "1" ]]; then
  if ${OC} get odhdashboardconfig odh-dashboard-config -n "${APPS_NS}" &>/dev/null; then
    log_info "Enabling observabilityDashboard on OdhDashboardConfig…"
    ${OC} patch odhdashboardconfig odh-dashboard-config -n "${APPS_NS}" --type=merge \
      -p '{"spec":{"dashboardConfig":{"observabilityDashboard":true}}}' || \
      log_warn "Could not patch OdhDashboardConfig (non-fatal)"
  else
    log_warn "OdhDashboardConfig not found in ${APPS_NS} — skip dashboard flag"
  fi
else
  log_info "Skipping dashboard flag (SKIP_DASHBOARD_FLAG=1)"
fi

#── 6. Perses NetworkPolicy (dashboard → Perses) ───────────────────────────────

apply_perses_dashboard_networkpolicy() {
  if ! ${OC} get namespace "${MONITORING_NS}" &>/dev/null; then
    log_warn "Monitoring namespace ${MONITORING_NS} missing — skip Perses NetworkPolicy"
    return 0
  fi
  log_info "Allowing dashboard namespaces to reach Perses (NetworkPolicy)…"
  if command -v envsubst &>/dev/null; then
    # shellcheck disable=SC2016
    MONITORING_NS="${MONITORING_NS}" envsubst '${MONITORING_NS}' \
      < "${OBS_DIR}/perses-dashboard-networkpolicy.yaml" | ${OC} apply -f -
  else
    sed "s|\${MONITORING_NS}|${MONITORING_NS}|g" \
      "${OBS_DIR}/perses-dashboard-networkpolicy.yaml" | ${OC} apply -f -
  fi
}

apply_perses_dashboard_networkpolicy

#── wait for MonitoringStackAvailable + Perses Ready ───────────────────────────

log_info "Waiting for DSCI MonitoringStackAvailable=True (timeout ${WAIT_TIMEOUT}s)…"
elapsed=0
while (( elapsed < WAIT_TIMEOUT )); do
  status="$(${OC} get dscinitialization "${DSCI_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].status}' 2>/dev/null || true)"
  reason="$(${OC} get dscinitialization "${DSCI_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="MonitoringStackAvailable")].reason}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "✅ MonitoringStackAvailable=True"
    break
  fi
  if (( elapsed % 30 == 0 )); then
    log_info "  status=${status:-unknown} reason=${reason:-unknown} (${elapsed}s)"
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

if [[ "${status:-}" != "True" ]]; then
  log_warn "MonitoringStackAvailable still not True after ${WAIT_TIMEOUT}s"
  log_warn "  Check: ${OC} get dscinitialization ${DSCI_NAME} -o yaml"
  log_warn "  Check: ${OC} get pods -n ${MONITORING_NS}"
  log_warn "  COO CSV: ${OC} get csv -n ${COO_NS}"
  log_warn "  OTEL CSV: ${OC} get csv -n ${OTEL_NS} | grep opentelemetry"
  exit 1
fi

# Perses Ready (dashboard backend) — optional wait; TLS skew hacks live under infra/hacks/
if ${OC} get sts -n "${MONITORING_NS}" 2>/dev/null | grep -qi perses; then
  log_info "Waiting for Perses pod Ready…"
  elapsed=0
  perses_ready=false
  while (( elapsed < 180 )); do
    if ${OC} get pods -n "${MONITORING_NS}" -l app.kubernetes.io/name=perses \
         -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
      perses_ready=true
      echo "✅ Perses Ready"
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if [[ "${perses_ready}" != "true" ]]; then
    log_warn "Perses still not Ready — check: ${OC} logs -n ${MONITORING_NS} -l app.kubernetes.io/name=perses --tail=50"
    log_warn "If logs show unsupported --web.tls-* flags, see infra/hacks/perses-tls-skew.hack.sh (not applied by this install)"
  fi
fi

echo ""
echo "✅ Observability configured for Showback/FinOps"
echo "  DSCI metrics.storage: ${METRICS_SIZE} / ${METRICS_RETENTION}"
echo "  Monitoring namespace:  ${MONITORING_NS}"
echo "  Perses NetworkPolicy:  perses-dashboard-access (dashboard → Perses :8080)"
echo ""
echo "Verify:"
echo "  ${OC} get dscinitialization ${DSCI_NAME} -o jsonpath='{.status.conditions[?(@.type==\"MonitoringStackAvailable\")]}{\"\\n\"}'"
echo "  ${OC} get monitoring -A"
echo "  ${OC} get monitoringstack -A"
echo "  ${OC} get pods -n ${MONITORING_NS}"
echo "  ${OC} get networkpolicy perses-dashboard-access -n ${MONITORING_NS}"
echo "  ${OC} get csv -n ${OTEL_NS} | grep opentelemetry"
echo "  ${OC} get crd opentelemetrycollectors.opentelemetry.io"

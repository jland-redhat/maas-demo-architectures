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
#   2. Patch DSCInitialization metrics.storage
#   3. Enable User Workload Monitoring (safe merge)
#   4. Enable Kuadrant observability (limitador metrics)
#   5. Enable observabilityDashboard on OdhDashboardConfig
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

if [[ "${SKIP_OPERATORS}" != "1" ]]; then
  log_info "Installing Cluster Observability Operator…"
  ${OC} apply -f "${OBS_DIR}/cluster-observability-operator.yaml"

  log_info "Installing OpenTelemetry Operator…"
  ${OC} apply -f "${OBS_DIR}/opentelemetry-operator.yaml"

  wait_for_crd monitoringstacks.monitoring.rhobs 300 || \
    log_warn "monitoringstacks.monitoring.rhobs CRD not ready yet (COO still installing)"
  wait_for_crd opentelemetrycollectors.opentelemetry.io 300 || \
    log_warn "opentelemetrycollectors.opentelemetry.io CRD not ready yet"
else
  log_info "Skipping operator install (SKIP_OPERATORS=1)"
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

#── wait for MonitoringStackAvailable ──────────────────────────────────────────

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
  log_warn "  COO CSV: ${OC} get csv -n openshift-cluster-observability-operator"
  log_warn "  OTEL CSV: ${OC} get csv -n openshift-operators | grep opentelemetry"
  exit 1
fi

echo ""
echo "✅ Observability configured for Showback/FinOps"
echo "  DSCI metrics.storage: ${METRICS_SIZE} / ${METRICS_RETENTION}"
echo "  Monitoring namespace:  ${MONITORING_NS}"
echo ""
echo "Verify:"
echo "  ${OC} get dscinitialization ${DSCI_NAME} -o jsonpath='{.status.conditions[?(@.type==\"MonitoringStackAvailable\")]}{\"\\n\"}'"
echo "  ${OC} get monitoringstack -A"
echo "  ${OC} get pods -n ${MONITORING_NS}"

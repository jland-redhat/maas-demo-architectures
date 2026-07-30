#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Install lab infrastructure prerequisites for this demo repo:
#   1. Kuadrant CR          (Authorino + Limitador instance)
#   2. maas-default-gateway (TLS listeners + authorino-tls-bootstrap)
#   3. Authorino TLS        (serving-cert + outbound CA trust → maas-api)
#   4. PostgreSQL           (postgres ns + maas-db-config Secret)
#   5. Observability        (DSCI metrics.storage → MonitoringStack / Showback)
#
# Does NOT install ODH/RHOAI operators, Kuadrant/RHCL operators, or MaaS itself.
# Those come from upstream: https://github.com/opendatahub-io/models-as-a-service
#
# Usage (from repo root):
#   ./infra/scripts/install-infra.sh
#   SKIP_GATEWAY=1 ./infra/scripts/install-infra.sh
#   SKIP_POSTGRES=1 ./infra/scripts/install-infra.sh
#   SKIP_OBSERVABILITY=1 ./infra/scripts/install-infra.sh
#   INGRESS_MODE=clusterip ./infra/scripts/install-infra.sh
#
# Prefer upstream scripts when MAAS_REPO is set:
#   MAAS_REPO=/path/to/models-as-a-service ./infra/scripts/install-infra.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${INFRA_DIR}/.." && pwd)"

SKIP_KUADRANT="${SKIP_KUADRANT:-0}"
SKIP_GATEWAY="${SKIP_GATEWAY:-0}"
SKIP_AUTHORINO_TLS="${SKIP_AUTHORINO_TLS:-0}"
SKIP_POSTGRES="${SKIP_POSTGRES:-0}"
SKIP_OBSERVABILITY="${SKIP_OBSERVABILITY:-0}"

# Prefer MAAS_REPO copies when present (stay closest to upstream)
use_maas() {
  local rel="$1"
  [[ -n "${MAAS_REPO:-}" && -x "${MAAS_REPO}/${rel}" ]]
}

run_step() {
  local title="$1"
  shift
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  ${title}"
  echo "═══════════════════════════════════════════════════════════════════"
  "$@"
}

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  maas-demo-architectures — install lab infra                    ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "Repo: ${REPO_ROOT}"
[[ -n "${MAAS_REPO:-}" ]] && echo "MAAS_REPO: ${MAAS_REPO} (prefer upstream scripts when available)"
echo ""
echo "Steps: kuadrant=${SKIP_KUADRANT} gateway=${SKIP_GATEWAY} authorino-tls=${SKIP_AUTHORINO_TLS} postgres=${SKIP_POSTGRES} observability=${SKIP_OBSERVABILITY}"
echo "       (0 = run, 1 = skip)"

# 1. Kuadrant CR
if [[ "${SKIP_KUADRANT}" != "1" ]]; then
  run_step "1/5 Kuadrant CR" "${SCRIPT_DIR}/setup-kuadrant.sh"
else
  echo "Skipping Kuadrant CR (SKIP_KUADRANT=1)"
fi

# 2. Gateway (TLS on listeners)
if [[ "${SKIP_GATEWAY}" != "1" ]]; then
  if use_maas scripts/setup-gateway.sh; then
    run_step "2/5 Gateway (upstream setup-gateway.sh)" \
      env INGRESS_MODE="${INGRESS_MODE:-route}" "${MAAS_REPO}/scripts/setup-gateway.sh"
  else
    run_step "2/5 Gateway (local setup-gateway.sh)" \
      env INGRESS_MODE="${INGRESS_MODE:-route}" "${SCRIPT_DIR}/setup-gateway.sh"
  fi
else
  echo "Skipping Gateway (SKIP_GATEWAY=1)"
fi

# 3. Authorino TLS
if [[ "${SKIP_AUTHORINO_TLS}" != "1" ]]; then
  if use_maas scripts/setup-authorino-tls.sh; then
    # Propagate auto-detected ns if user did not set AUTHORINO_NAMESPACE
    if [[ -z "${AUTHORINO_NAMESPACE:-}" ]]; then
      # Local detector prefers RHCL then kuadrant-system
      if command -v oc &>/dev/null; then
        if oc get authorino authorino -n rh-connectivity-link &>/dev/null; then
          export AUTHORINO_NAMESPACE=rh-connectivity-link
        elif oc get authorino authorino -n kuadrant-system &>/dev/null; then
          export AUTHORINO_NAMESPACE=kuadrant-system
        fi
      fi
    fi
    run_step "3/5 Authorino TLS (upstream setup-authorino-tls.sh)" \
      "${MAAS_REPO}/scripts/setup-authorino-tls.sh"
  else
    run_step "3/5 Authorino TLS (local setup-authorino-tls.sh)" \
      "${SCRIPT_DIR}/setup-authorino-tls.sh"
  fi
else
  echo "Skipping Authorino TLS (SKIP_AUTHORINO_TLS=1)"
fi

# 4. Postgres + maas-db-config
if [[ "${SKIP_POSTGRES}" != "1" ]]; then
  run_step "4/5 PostgreSQL + maas-db-config" "${SCRIPT_DIR}/setup-postgres.sh"
else
  echo "Skipping Postgres (SKIP_POSTGRES=1)"
fi

# 5. Observability (DSCI metrics → MonitoringStack / Showback)
if [[ "${SKIP_OBSERVABILITY}" != "1" ]]; then
  run_step "5/5 Observability (DSCI metrics + Showback)" "${SCRIPT_DIR}/setup-observability.sh"
else
  echo "Skipping Observability (SKIP_OBSERVABILITY=1)"
fi

echo ""
echo "✅ Lab infra install finished"
echo ""
echo "Next:"
echo "  • Ensure ODH/RHOAI DataScienceCluster has modelsAsAService Managed"
echo "  • Apply demo workloads:  oc apply -k deploy/overlays/demo08   # example"
echo "  • Docs: ${INFRA_DIR}/README.md"
echo ""

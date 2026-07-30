#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Apply the Kuadrant CR so Authorino/Limitador are reconciled.
# Does NOT install the Kuadrant/RHCL operator — that must already be present
# (ODH: Kuadrant; RHOAI: Red Hat Connectivity Link).
#
# Upstream CR: scripts/data/kuadrant.yaml in opendatahub-io/models-as-a-service
#
# Usage (from repo root):
#   ./infra/scripts/setup-kuadrant.sh
#   KUADRANT_NAMESPACE=rh-connectivity-link ./infra/scripts/setup-kuadrant.sh
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

detect_kuadrant_namespace() {
  if [[ -n "${KUADRANT_NAMESPACE:-}" ]]; then
    echo "${KUADRANT_NAMESPACE}"
    return 0
  fi
  # Prefer RHCL when present (RHOAI), else upstream Kuadrant (ODH)
  if ${OC} get crd kuadrants.kuadrant.io &>/dev/null; then
    if ${OC} get namespace rh-connectivity-link &>/dev/null && \
       ${OC} get deployment -n rh-connectivity-link -l app.kubernetes.io/name=kuadrant-operator --no-headers 2>/dev/null | grep -q .; then
      echo "rh-connectivity-link"
      return 0
    fi
    if ${OC} get namespace kuadrant-system &>/dev/null; then
      echo "kuadrant-system"
      return 0
    fi
  fi
  # Default for ODH-style installs
  echo "kuadrant-system"
}

NS="$(detect_kuadrant_namespace)"

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  Kuadrant CR (Authorino + Limitador via operator)               ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "Namespace: ${NS}"
echo ""

if ! ${OC} get crd kuadrants.kuadrant.io &>/dev/null; then
  echo "ERROR: Kuadrant CRD not found. Install Kuadrant (ODH) or RHCL (RHOAI) first." >&2
  echo "  Docs: https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/platform-setup.md" >&2
  exit 1
fi

${OC} get namespace "${NS}" &>/dev/null || ${OC} create namespace "${NS}"

echo "Applying Kuadrant/kuadrant…"
${OC} apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: maas-demo-architectures
spec: {}
EOF

echo "Waiting for Kuadrant Ready…"
timeout=180
elapsed=0
while (( elapsed < timeout )); do
  ready="$(${OC} get kuadrant kuadrant -n "${NS}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${ready}" == "True" ]]; then
    echo "✅ Kuadrant is Ready in ${NS}"
    exit 0
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

echo "⚠️  Kuadrant not Ready after ${timeout}s — check: ${OC} describe kuadrant kuadrant -n ${NS}"
exit 1

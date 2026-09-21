#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Ensure MaaS Gateway listeners allow HTTPRoutes from All namespaces.
#
# setup-gateway.sh creates listeners with allowedRoutes.namespaces.from: All, but
# some RHOAI AIGateway reconciles (migrateSelector) rewrite that to a Selector
# limited to redhat-ods-applications / redhat-ai-gateway-infra. Model HTTPRoutes
# in llm / llm-partner / llm-oidc then fail Accepted with NotAllowedByListeners,
# and MaaSModelRefs stay BackendNotReady / HTTPRoutesNotReady.
#
# Usage (from repo root):
#   ./infra/scripts/ensure-gateway-allowed-routes.sh
#   ./infra/scripts/ensure-gateway-allowed-routes.sh maas-default-gateway partner oidc
#
# Env:
#   GATEWAY_NAMESPACE  default openshift-ingress
#   GATEWAY_NAMES      space-separated names (default: maas-default-gateway)
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

GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"

if [[ "$#" -gt 0 ]]; then
  GATEWAYS=("$@")
else
  # shellcheck disable=SC2206
  GATEWAYS=(${GATEWAY_NAMES:-maas-default-gateway})
fi

ensure_one() {
  local name="$1"
  if ! ${OC} get gateway "${name}" -n "${GATEWAY_NAMESPACE}" &>/dev/null; then
    echo "skip: gateway ${GATEWAY_NAMESPACE}/${name} not found"
    return 0
  fi

  local needs
  needs="$(${OC} get gateway "${name}" -n "${GATEWAY_NAMESPACE}" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
bad=[]
for i,l in enumerate(d.get("spec",{}).get("listeners") or []):
  ar=(l.get("allowedRoutes") or {}).get("namespaces") or {}
  if ar.get("from") != "All":
    bad.append("%s(%s)" % (l.get("name") or i, ar.get("from") or "unset"))
print(" ".join(bad) if bad else "ok")
')"

  if [[ "${needs}" == "ok" ]]; then
    echo "✓ ${GATEWAY_NAMESPACE}/${name}: allowedRoutes already from All"
    return 0
  fi

  echo "Patching ${GATEWAY_NAMESPACE}/${name}: listeners ${needs} → from All…"
  ${OC} get gateway "${name}" -n "${GATEWAY_NAMESPACE}" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for l in d.get("spec",{}).get("listeners") or []:
  l["allowedRoutes"]={"namespaces":{"from":"All"}}
ann=d["metadata"].setdefault("annotations", {})
ann["opendatahub.io/managed"]="false"
ann["maas-demo-architectures/allowed-routes"]="All"
# Avoid SSA / managedFields fights on replace
d["metadata"].pop("managedFields", None)
d["metadata"].pop("resourceVersion", None)
json.dump(d, sys.stdout)
' | ${OC} replace -f -

  echo "✓ ${GATEWAY_NAMESPACE}/${name}: listeners allow routes from All"
}

for gw in "${GATEWAYS[@]}"; do
  ensure_one "${gw}"
done

#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Ensure MaaSModelRef CRD accepts spec.tenantRef (and status.resolvedTenantRef).
#
# Some RHOAI/ODH builds ship a MaaSModelRef CRD that omits tenantRef. kubectl then
# warns "unknown field spec.tenantRef" and drops it, so multi-tenant models stay
# bound to maas-default-gateway and fail Ready when their LLMInferenceService
# targets a dedicated Gateway (partner / oidc).
#
# Usage (from repo root):
#   ./infra/scripts/ensure-maasmodelref-tenantref.sh
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

CRD=maasmodelrefs.maas.opendatahub.io
if ! ${OC} get crd "${CRD}" &>/dev/null; then
  echo "ERROR: CRD ${CRD} not found — install MaaS / RHOAI modelsAsAService first" >&2
  exit 1
fi

has_tenantref="$(${OC} get crd "${CRD}" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
props=d["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]
print("yes" if "tenantRef" in props else "no")
')"

if [[ "${has_tenantref}" == "yes" ]]; then
  echo "✓ ${CRD} already has spec.tenantRef"
  exit 0
fi

echo "Patching ${CRD} to add spec.tenantRef + status.resolvedTenantRef…"
${OC} get crd "${CRD}" -o json | python3 -c '
import json,sys
crd=json.load(sys.stdin)
v=crd["spec"]["versions"][0]
schema=v["schema"]["openAPIV3Schema"]["properties"]
spec_props=schema["spec"]["properties"]
status_props=schema["status"]["properties"]
spec_props["tenantRef"]={
  "description": "TenantRef is the name of the AITenant this model belongs to. When omitted, the model is assigned to the default tenant.",
  "maxLength": 253,
  "pattern": "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$",
  "type": "string",
}
status_props["resolvedTenantRef"]={
  "description": "ResolvedTenantRef is the name of the AITenant this model was resolved to.",
  "type": "string",
}
crd["metadata"].pop("resourceVersion", None)
crd["metadata"].pop("managedFields", None)
ann=crd["metadata"].setdefault("annotations", {})
ann["opendatahub.io/managed"]="false"
ann["maas-demo-architectures/tenantref-schema"]="true"
json.dump(crd, sys.stdout)
' | ${OC} replace -f -

echo "✓ ${CRD} updated (opendatahub.io/managed=false to reduce platform overwrite)"
echo "  Re-apply tenant MaaSModelRefs so spec.tenantRef is stored:"
echo "    oc apply -f demos/08-maas-35-features/manifests/oidc-models.yaml"
echo "    oc apply -f demos/08-maas-35-features/manifests/partner-models.yaml"

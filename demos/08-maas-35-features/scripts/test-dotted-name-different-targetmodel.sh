#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Validate an external model where kube name == body.model (plain catalog id) but
# targetModel differs and contains a dot. The llm-katan simulator echoes the
# targetModel it receives; a PASS means response.model == TARGET_MODEL, not MODEL_ID.
#
# Usage (from repo root):
#   ./demos/08-maas-35-features/scripts/test-dotted-name-different-targetmodel.sh
#
# Optional env:
#   MODEL_ID=vendor-model
#   TARGET_MODEL=vendor.echo-alias
#   MODELS_NS=llm
#   SUBSCRIPTION_NS=models-as-a-service
#   SUBSCRIPTION_NAME=validation-external-model
#   AUTH_POLICY_NAME=validation-external-model-access
#   SKIP_APPLY=1
#   INFERENCE_BEARER=...   # skip minting; use this bearer (e.g. oc whoami -t)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODEL_ID="${MODEL_ID:-vendor-model}"
TARGET_MODEL="${TARGET_MODEL:-vendor.echo-alias}"
MODELS_NS="${MODELS_NS:-llm}"
SUBSCRIPTION_NS="${SUBSCRIPTION_NS:-models-as-a-service}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-validation-external-model}"
AUTH_POLICY_NAME="${AUTH_POLICY_NAME:-validation-external-model-access}"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,22p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: oc is required" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "Error: curl and jq are required" >&2
  exit 1
fi

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Error: could not resolve OpenShift cluster domain" >&2
  exit 1
fi
HOST="https://maas.${CLUSTER_DOMAIN}"

apply_entitlement() {
  local cr="$1" name="$2"
  python3 - "$cr" "$name" "$MODEL_ID" "$MODELS_NS" "$SUBSCRIPTION_NS" <<'PY'
import json, subprocess, sys
cr, name, model, models_ns, sub_ns = sys.argv[1:6]
try:
    obj = json.loads(subprocess.check_output(["oc", "get", cr, name, "-n", sub_ns, "-o", "json"]))
except subprocess.CalledProcessError:
    print(f"skip {cr}/{name} (not found)", file=sys.stderr)
    sys.exit(0)
refs = obj["spec"]["modelRefs"]
if any(r["name"] == model for r in refs):
    sys.exit(0)
entry = {"name": model, "namespace": models_ns}
if cr == "maassubscription":
    entry["tokenRateLimits"] = [{"limit": 200, "window": "1m"}]
refs.append(entry)
obj["spec"]["modelRefs"] = refs
subprocess.run(["oc", "apply", "-f", "-"], input=json.dumps(obj).encode(), check=True)
print(f"added {model} to {cr}/{name}")
PY
}

if [[ "${SKIP_APPLY:-}" != "1" ]]; then
  echo "Applying provider + ${MODEL_ID} (targetModel=${TARGET_MODEL})…"
  oc apply -f "${DEMO_DIR}/manifests/external-model.yaml"

  echo "Ensuring subscription / auth policy include ${MODEL_ID}…"
  apply_entitlement maassubscription "${SUBSCRIPTION_NAME}"
  apply_entitlement maasauthpolicy "${AUTH_POLICY_NAME}"

  echo "Waiting for ExternalModel + MaaSModelRef Ready…"
  for _ in $(seq 1 24); do
    em_phase="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    mr_phase="$(oc get maasmodelref "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${em_phase}" == "Ready" && "${mr_phase}" == "Ready" ]]; then
      break
    fi
    sleep 5
  done
fi

em_phase="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
mr_phase="$(oc get maasmodelref "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${em_phase}" != "Ready" || "${mr_phase}" != "Ready" ]]; then
  echo "Error: ${MODEL_ID} not Ready (externalmodel=${em_phase}, maasmodelref=${mr_phase})" >&2
  exit 1
fi

kube_name="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.metadata.name}')"
target="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.externalProviderRefs[0].targetModel}')"
model_name_field="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.modelName}' 2>/dev/null || true)"

if [[ "${kube_name}" != "${MODEL_ID}" ]]; then
  echo "Error: kube name ${kube_name} != MODEL_ID ${MODEL_ID}" >&2
  exit 1
fi
if [[ "${target}" != "${TARGET_MODEL}" ]]; then
  echo "Error: targetModel ${target} != TARGET_MODEL ${TARGET_MODEL}" >&2
  exit 1
fi
if [[ "${target}" == "${kube_name}" ]]; then
  echo "Error: targetModel must differ from kube/catalog id" >&2
  exit 1
fi
if [[ -n "${model_name_field}" ]]; then
  echo "Error: spec.modelName is set (${model_name_field}); this test uses kube name only" >&2
  exit 1
fi
if [[ "${TARGET_MODEL}" != *.* ]]; then
  echo "Error: TARGET_MODEL must contain a dot" >&2
  exit 1
fi

OC_TOKEN="$(oc whoami -t)"
if [[ -n "${INFERENCE_BEARER:-}" ]]; then
  KEY="${INFERENCE_BEARER}"
  echo "Using INFERENCE_BEARER from env…"
else
  echo "Minting API key (subscription=${SUBSCRIPTION_NAME})…"
  KEY="$(
    curl -sSk \
      -H "Authorization: Bearer ${OC_TOKEN}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d "{\"expiresIn\":\"1h\",\"name\":\"dotted-target-$(date +%s)\",\"subscription\":\"${SUBSCRIPTION_NAME}\"}" \
      "${HOST}/maas-api/v1/api-keys" | jq -r '.key'
  )"
  if [[ -z "${KEY}" || "${KEY}" == "null" ]]; then
    echo "Error: failed to mint API key" >&2
    exit 1
  fi
fi

echo "Probing POST ${HOST}/v1/chat/completions"
echo "  body.model=${MODEL_ID} (expect backend targetModel=${TARGET_MODEL})…"
resp="$(curl -sSk -w $'\n__HTTP__%{http_code}' --http1.1 \
  -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"targetModel probe\"}],\"max_tokens\":24}" \
  "${HOST}/v1/chat/completions")"
http_code="$(printf '%s' "${resp}" | sed -n '$s/.*__HTTP__//p')"
body="$(printf '%s' "${resp}" | sed '$d')"

if [[ "${http_code}" != "200" && "${http_code}" == "403" && -z "${INFERENCE_BEARER:-}" ]]; then
  echo "API key probe returned HTTP 403; retrying with OpenShift token…" >&2
  KEY="${OC_TOKEN}"
  resp="$(curl -sSk -w $'\n__HTTP__%{http_code}' --http1.1 \
    -H "Authorization: Bearer ${KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"targetModel probe\"}],\"max_tokens\":24}" \
    "${HOST}/v1/chat/completions")"
  http_code="$(printf '%s' "${resp}" | sed -n '$s/.*__HTTP__//p')"
  body="$(printf '%s' "${resp}" | sed '$d')"
fi

if [[ "${http_code}" != "200" ]]; then
  echo "FAIL: HTTP ${http_code}" >&2
  printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
  exit 1
fi

resp_model="$(printf '%s' "${body}" | jq -r '.model // empty')"
if [[ "${resp_model}" != "${TARGET_MODEL}" ]]; then
  echo "FAIL: response model=${resp_model}, expected targetModel=${TARGET_MODEL}" >&2
  echo "      (request used body.model=${MODEL_ID})" >&2
  printf '%s\n' "${body}" | jq .
  exit 1
fi
if [[ "${resp_model}" == "${MODEL_ID}" ]]; then
  echo "FAIL: backend received catalog id instead of targetModel" >&2
  printf '%s\n' "${body}" | jq .
  exit 1
fi

echo "PASS: body.model=${MODEL_ID} routed with targetModel=${TARGET_MODEL}"
printf '%s\n' "${body}" | jq '{request_model:"'"${MODEL_ID}"'",response_model:.model,content:.choices[0].message.content}'

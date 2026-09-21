#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Validate an external model where kube name, catalog id, and targetModel are
# identical and contain a dot (e.g. openai.gpt-oss-20b). The llm-katan simulator
# echoes any model string back; this test only checks gateway routing + auth.
#
# Usage (from repo root):
#   ./demos/08-maas-35-features/scripts/test-dotted-same-name-model.sh
#
# Optional env:
#   MODEL_ID=openai.gpt-oss-20b
#   MODELS_NS=llm
#   SUBSCRIPTION_NS=models-as-a-service
#   SUBSCRIPTION_NAME=validation-external-model
#   AUTH_POLICY_NAME=validation-external-model-access
#   SKIP_APPLY=1          # only run the inference probe (objects already exist)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODEL_ID="${MODEL_ID:-openai.gpt-oss-20b}"
MODELS_NS="${MODELS_NS:-llm}"
SUBSCRIPTION_NS="${SUBSCRIPTION_NS:-models-as-a-service}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-validation-external-model}"
AUTH_POLICY_NAME="${AUTH_POLICY_NAME:-validation-external-model-access}"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,20p' "$0"
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
  echo "Applying provider + dotted same-name external model (${MODEL_ID})…"
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

target="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.externalProviderRefs[0].targetModel}')"
kube_name="$(oc get externalmodel "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.metadata.name}')"
if [[ "${target}" != "${kube_name}" || "${target}" != "${MODEL_ID}" ]]; then
  echo "Error: expected kube name == targetModel == MODEL_ID (${kube_name} / ${target} / ${MODEL_ID})" >&2
  exit 1
fi
if [[ "${MODEL_ID}" != *.* ]]; then
  echo "Error: MODEL_ID must contain a dot" >&2
  exit 1
fi

echo "Minting API key (subscription=${SUBSCRIPTION_NAME})…"
OC_TOKEN="$(oc whoami -t)"
KEY="$(
  curl -sSk \
    -H "Authorization: Bearer ${OC_TOKEN}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "{\"expiresIn\":\"1h\",\"name\":\"dotted-same-name-$(date +%s)\",\"subscription\":\"${SUBSCRIPTION_NAME}\"}" \
    "${HOST}/maas-api/v1/api-keys" | jq -r '.key'
)"
if [[ -z "${KEY}" || "${KEY}" == "null" ]]; then
  echo "Error: failed to mint API key" >&2
  exit 1
fi

echo "Probing POST ${HOST}/v1/chat/completions with model=${MODEL_ID}…"
resp="$(curl -sSk -w $'\n__HTTP__%{http_code}' --http1.1 \
  -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"dotted same-name test\"}],\"max_tokens\":24}" \
  "${HOST}/v1/chat/completions")"
http_code="$(printf '%s' "${resp}" | sed -n '$s/.*__HTTP__//p')"
body="$(printf '%s' "${resp}" | sed '$d')"

if [[ "${http_code}" != "200" ]]; then
  echo "FAIL: HTTP ${http_code}" >&2
  printf '%s\n' "${body}" | jq . 2>/dev/null || printf '%s\n' "${body}"
  exit 1
fi

resp_model="$(printf '%s' "${body}" | jq -r '.model // empty')"
if [[ "${resp_model}" != "${MODEL_ID}" ]]; then
  echo "FAIL: response model=${resp_model}, expected ${MODEL_ID}" >&2
  printf '%s\n' "${body}" | jq .
  exit 1
fi

echo "PASS: dotted same-name external model works"
printf '%s\n' "${body}" | jq '{model:.model, content:.choices[0].message.content}'

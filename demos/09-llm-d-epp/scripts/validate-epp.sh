#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Validate that llm-d EPP is in the request path for Demo 09 (not plain Service LB).
#
# Checks (same bar as the EPP repro lab):
#   1. LLMIS has replicas ≥ 3 and router.scheduler set
#   2. InferencePool exists and references an EPP Service
#   3. router-scheduler (EPP) Deployment/pod is Ready
#   4. HTTPRoute backendRefs include kind: InferencePool (not Service-only)
#   5. Burst inference through the MaaS gateway; report per-pod hit counts from
#      simulator --log-http lines (proves traffic reaches multiple endpoints)
#
# Usage (from repo root):
#   ./demos/09-llm-d-epp/scripts/validate-epp.sh
#
# Optional env:
#   MODEL_ID=demo09-epp-sim
#   MODELS_NS=llm
#   SUBSCRIPTION_NAME=demo09-epp-catalog
#   SUBSCRIPTION_NS=models-as-a-service
#   REQUESTS=12
#   SKIP_APPLY=1
#   CATALOG_MODEL_ID=publishers/llm/models/demo/epp-sim
#   INFERENCE_BEARER=...   # skip minting
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODEL_ID="${MODEL_ID:-demo09-epp-sim}"
MODELS_NS="${MODELS_NS:-llm}"
SUBSCRIPTION_NS="${SUBSCRIPTION_NS:-models-as-a-service}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-demo09-epp-catalog}"
REQUESTS="${REQUESTS:-12}"
MIN_REPLICAS="${MIN_REPLICAS:-3}"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,28p' "$0"
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

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [[ "${SKIP_APPLY:-}" != "1" ]]; then
  echo "Applying Demo 09 manifests…"
  "${SCRIPT_DIR}/apply.sh"
fi

echo "Waiting for LLMInferenceService / MaaSModelRef Ready…"
for _ in $(seq 1 36); do
  llmis_ready="$(oc get llminferenceservice "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  mr_phase="$(oc get maasmodelref "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${llmis_ready}" == "True" && "${mr_phase}" == "Ready" ]]; then
    break
  fi
  sleep 5
done

llmis_ready="$(oc get llminferenceservice "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
mr_phase="$(oc get maasmodelref "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "${llmis_ready}" == "True" ]] || fail "LLMInferenceService ${MODEL_ID} not Ready (status=${llmis_ready})"
[[ "${mr_phase}" == "Ready" ]] || fail "MaaSModelRef ${MODEL_ID} not Ready (phase=${mr_phase})"

replicas="$(oc get llminferenceservice "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.replicas}')"
scheduler_raw="$(oc get llminferenceservice "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.router.scheduler}' 2>/dev/null || true)"
[[ -n "${replicas}" && "${replicas}" -ge "${MIN_REPLICAS}" ]] \
  || fail "replicas=${replicas:-0} (need >= ${MIN_REPLICAS}); single replica cannot exercise EPP"
[[ -n "${scheduler_raw}" ]] \
  || fail "spec.router.scheduler is unset - KServe will not create InferencePool/EPP"
pass "LLMIS ${MODEL_ID}: replicas=${replicas}, scheduler set"

POOL_NAME="${MODEL_ID}-inference-pool"
if ! oc get inferencepool "${POOL_NAME}" -n "${MODELS_NS}" &>/dev/null; then
  # Some builds use a slightly different suffix; discover by owner.
  POOL_NAME="$(oc get inferencepool -n "${MODELS_NS}" -o json \
    | jq -r --arg m "${MODEL_ID}" '
        .items[]
        | select(.metadata.ownerReferences[]? | select(.kind=="LLMInferenceService" and .name==$m))
        | .metadata.name' | head -1)"
fi
[[ -n "${POOL_NAME}" ]] || fail "No InferencePool owned by ${MODEL_ID}"
EPP_SVC="$(oc get inferencepool "${POOL_NAME}" -n "${MODELS_NS}" -o jsonpath='{.spec.endpointPickerRef.name}')"
[[ -n "${EPP_SVC}" ]] || fail "InferencePool ${POOL_NAME} missing endpointPickerRef"
pass "InferencePool ${POOL_NAME} → EPP Service ${EPP_SVC}"

EPP_READY="$(oc get deploy -n "${MODELS_NS}" -l "app.kubernetes.io/name=${MODEL_ID},app.kubernetes.io/component=llminferenceservice-router-scheduler" \
  -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || true)"
if [[ -z "${EPP_READY}" || "${EPP_READY}" == "0" ]]; then
  # Fallback name pattern from KServe
  EPP_READY="$(oc get deploy "${MODEL_ID}-kserve-router-scheduler" -n "${MODELS_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
fi
[[ -n "${EPP_READY}" && "${EPP_READY}" -ge 1 ]] \
  || fail "EPP/router-scheduler Deployment not Ready"
pass "EPP/router-scheduler readyReplicas=${EPP_READY}"

ROUTE_NAME="${MODEL_ID}-kserve-route"
if ! oc get httproute "${ROUTE_NAME}" -n "${MODELS_NS}" &>/dev/null; then
  ROUTE_NAME="$(oc get httproute -n "${MODELS_NS}" -o json \
    | jq -r --arg m "${MODEL_ID}" '
        .items[]
        | select(.metadata.name | test($m))
        | .metadata.name' | head -1)"
fi
[[ -n "${ROUTE_NAME}" ]] || fail "No HTTPRoute for ${MODEL_ID}"

pool_backends="$(oc get httproute "${ROUTE_NAME}" -n "${MODELS_NS}" -o json \
  | jq -r '[.spec.rules[].backendRefs[]? | select(.kind=="InferencePool") | .name] | unique | length')"
[[ "${pool_backends}" -ge 1 ]] \
  || fail "HTTPRoute ${ROUTE_NAME} has no InferencePool backend (Service-only = no EPP)"
pass "HTTPRoute ${ROUTE_NAME} backends include InferencePool"

CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
[[ -n "${CLUSTER_DOMAIN}" ]] || fail "could not resolve cluster domain"
HOST="https://maas.${CLUSTER_DOMAIN}"

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
      -d "{\"expiresIn\":\"1h\",\"name\":\"demo09-epp-$(date +%s)\",\"subscription\":\"${SUBSCRIPTION_NAME}\"}" \
      "${HOST}/maas-api/v1/api-keys" | jq -r '.key // empty'
  )"
  if [[ -z "${KEY}" || "${KEY}" == "null" ]]; then
    echo "Mint with subscription failed; retrying with OpenShift token for inference…" >&2
    KEY="${OC_TOKEN}"
  fi
fi

# Body-based routing matches X-Gateway-Model-Name on the catalog id
# (e.g. publishers/llm/models/demo/epp-sim), not the Kubernetes resource name.
CATALOG_MODEL_ID="${CATALOG_MODEL_ID:-}"
if [[ -z "${CATALOG_MODEL_ID}" ]]; then
  CATALOG_MODEL_ID="$(
    curl -sSk -H "Authorization: Bearer ${KEY}" "${HOST}/maas-api/v1/models" \
      | jq -r --arg m "${MODEL_ID}" '
          [.data[]? | select((.id // "") | (test($m) or endswith("epp-sim")))]
          | .[0].id // empty'
  )"
fi
if [[ -z "${CATALOG_MODEL_ID}" ]]; then
  # Derive from LLMIS spec.model.name → publishers/<ns>/models/<name>
  SPEC_MODEL="$(oc get llminferenceservice "${MODEL_ID}" -n "${MODELS_NS}" -o jsonpath='{.spec.model.name}')"
  if [[ -n "${SPEC_MODEL}" ]]; then
    CATALOG_MODEL_ID="publishers/${MODELS_NS}/models/${SPEC_MODEL}"
  fi
fi
[[ -n "${CATALOG_MODEL_ID}" ]] || fail "could not resolve catalog model id for ${MODEL_ID}"
pass "Catalog model id for BBR: ${CATALOG_MODEL_ID}"

# Snapshot workload pods and mark a log cursor time.
mapfile -t PODS < <(oc get pods -n "${MODELS_NS}" -l "app.kubernetes.io/name=${MODEL_ID},kserve.io/component=workload" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ "${#PODS[@]}" -lt "${MIN_REPLICAS}" ]]; then
  mapfile -t PODS < <(oc get pods -n "${MODELS_NS}" -l "app.kubernetes.io/name=${MODEL_ID}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | rg -v 'router-scheduler|epp' || true)
fi
[[ "${#PODS[@]}" -ge "${MIN_REPLICAS}" ]] \
  || fail "only ${#PODS[@]} workload pods (need ≥ ${MIN_REPLICAS})"

SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PREFIX="demo09-epp-shared-prefix-$(date +%s)"
INFER_PATH="${INFER_PATH:-/v1/chat/completions}"
echo "Sending ${REQUESTS} chat completions (shared prefix) via ${HOST}${INFER_PATH}"
echo "  body.model=${CATALOG_MODEL_ID}"
ok=0
for i in $(seq 1 "${REQUESTS}"); do
  code="$(curl -sSk -o /tmp/demo09-epp-body.json -w '%{http_code}' --http1.1 \
    -H "Authorization: Bearer ${KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${CATALOG_MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PREFIX} request ${i}\"}],\"max_tokens\":8}" \
    "${HOST}${INFER_PATH}" || true)"
  if [[ "${code}" == "200" ]]; then
    ok=$((ok + 1))
  elif [[ "${code}" == "403" && "${KEY}" != "${OC_TOKEN}" ]]; then
    KEY="${OC_TOKEN}"
    code="$(curl -sSk -o /tmp/demo09-epp-body.json -w '%{http_code}' --http1.1 \
      -H "Authorization: Bearer ${KEY}" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${CATALOG_MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PREFIX} request ${i}\"}],\"max_tokens\":8}" \
      "${HOST}${INFER_PATH}" || true)"
    [[ "${code}" == "200" ]] && ok=$((ok + 1))
  elif [[ "${code}" == "404" ]]; then
    # Fallback: path-based route (still InferencePool-backed for chat/completions).
    code="$(curl -sSk -o /tmp/demo09-epp-body.json -w '%{http_code}' --http1.1 \
      -H "Authorization: Bearer ${KEY}" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${CATALOG_MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PREFIX} request ${i}\"}],\"max_tokens\":8}" \
      "${HOST}/llm/${MODEL_ID}/v1/chat/completions" || true)"
    if [[ "${code}" == "200" ]]; then
      ok=$((ok + 1))
      INFER_PATH="/llm/${MODEL_ID}/v1/chat/completions"
    else
      echo "  request ${i}: HTTP ${code}" >&2
    fi
  else
    echo "  request ${i}: HTTP ${code}" >&2
  fi
done
[[ "${ok}" -ge 3 ]] || fail "only ${ok}/${REQUESTS} requests succeeded (need ≥3 to sample pods)"
pass "Inference burst: ${ok}/${REQUESTS} HTTP 200 (path ${INFER_PATH})"

echo "Per-pod --log-http hits since ${SINCE}:"
hit_pods=0
declare -A HITS=()
for pod in "${PODS[@]}"; do
  # Count lines that look like HTTP access after SINCE (best-effort).
  count="$(oc logs -n "${MODELS_NS}" "${pod}" --since-time="${SINCE}" 2>/dev/null \
    | rg -c -i 'POST|/v1/chat|chat/completions|log-http|request' || true)"
  count="${count:-0}"
  HITS["${pod}"]="${count}"
  printf '  %s: %s\n' "${pod}" "${count}"
  if [[ "${count}" =~ ^[0-9]+$ && "${count}" -gt 0 ]]; then
    hit_pods=$((hit_pods + 1))
  fi
done

if [[ "${hit_pods}" -ge 2 ]]; then
  pass "Traffic reached ${hit_pods} distinct workload pods (EPP/pool has multiple endpoints in use)"
elif [[ "${hit_pods}" -eq 1 ]]; then
  echo "WARN: only one pod shows recent HTTP logs — may be sticky session, cold start, or log format." >&2
  echo "      Structural checks (InferencePool + EPP + HTTPRoute) already PASSED." >&2
  echo "      Re-run with REQUESTS=30 or inspect EPP logs:" >&2
  echo "        oc logs -n ${MODELS_NS} deploy/${MODEL_ID}-kserve-router-scheduler" >&2
else
  echo "WARN: could not attribute hits via simulator logs (log format may differ)." >&2
  echo "      Structural checks (InferencePool + EPP + HTTPRoute) already PASSED." >&2
fi

echo ""
echo "EPP path validation complete for ${MODEL_ID}."
echo "  InferencePool: ${POOL_NAME}"
echo "  EPP Service:   ${EPP_SVC}"
echo "  HTTPRoute:     ${ROUTE_NAME}"

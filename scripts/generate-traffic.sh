#!/usr/bin/env bash
# Generate chat-completion traffic through MaaS gateways so observability
# (vLLM Prometheus metrics) is not stuck at zero.
#
# Default: body-based routing via each tenant gateway, using model IDs from
# GET /maas-api/v1/models. Mints an API key per gateway with oc whoami -t when
# MAAS_API_KEY / PARTNER_API_KEY / OIDC_API_KEY are unset.
#
# Usage (from repo root, cluster logged in via oc):
#   ./scripts/generate-traffic.sh
#   ./scripts/generate-traffic.sh --requests 10 --max-tokens 128
#   ./scripts/generate-traffic.sh --gateways maas,partner-maas
#   ./scripts/generate-traffic.sh --models sim-chat,granite
#   MAAS_API_KEY=sk-oai-... ./scripts/generate-traffic.sh --gateways maas
#   ./scripts/generate-traffic.sh --direct   # in-cluster workload Services (no key)
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

REQUESTS="${REQUESTS:-5}"
MAX_TOKENS="${MAX_TOKENS:-64}"
# Comma-separated Gateway Route names under apps domain (maas → https://maas.<domain>).
GATEWAYS="${GATEWAYS:-maas,partner-maas}"
MODELS_FILTER="${MODELS_FILTER:-}"
DIRECT=0
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.5.0}"
RUNNER_NS="${RUNNER_NS:-llm}"
NAMESPACES="${NAMESPACES:-}"
OUT_DIR="${TMPDIR:-/tmp}/maas-traffic-$$"
mkdir -p "${OUT_DIR}"
trap 'rm -rf "${OUT_DIR}"' EXIT

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --requests) REQUESTS="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    --gateways) GATEWAYS="$2"; shift 2 ;;
    --models) MODELS_FILTER="$2"; shift 2 ;;
    --direct) DIRECT=1; shift ;;
    --namespaces) NAMESPACES="$2"; shift 2 ;;
    --runner-ns) RUNNER_NS="$2"; shift 2 ;;
    # Back-compat aliases
    --via-gateway) DIRECT=0; shift ;;
    --mint-key) shift ;; # minting is default when keys unset
    --gateway-url)
      GATEWAYS="$2"
      shift 2
      ;;
    --api-key) MAAS_API_KEY="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

log() { printf '➜ %s\n' "$*" >&2; }
err() { printf 'ERROR: %s\n' "$*" >&2; }

DOMAIN="$("${OC}" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
OC_TOKEN="$("${OC}" whoami -t)"

gateway_base() {
  local g="$1"
  if [[ "${g}" == https://* || "${g}" == http://* ]]; then
    printf '%s' "${g%/}"
  else
    printf 'https://%s.%s' "${g}" "${DOMAIN}"
  fi
}

# Key env vars: MAAS_API_KEY (default/maas), PARTNER_API_KEY, OIDC_API_KEY
key_for_gateway() {
  local g="$1" base name
  base="$(gateway_base "${g}")"
  name="${base#https://}"
  name="${name#http://}"
  name="${name%%.*}"
  case "${name}" in
    maas)
      [[ -n "${MAAS_API_KEY:-}" ]] && { printf '%s' "${MAAS_API_KEY}"; return; }
      ;;
    partner-maas)
      [[ -n "${PARTNER_API_KEY:-}" ]] && { printf '%s' "${PARTNER_API_KEY}"; return; }
      ;;
    oidc-maas)
      [[ -n "${OIDC_API_KEY:-}" ]] && { printf '%s' "${OIDC_API_KEY}"; return; }
      ;;
  esac
  return 0
}

store_key() {
  local base="$1" key="$2"
  case "${base#https://}" in
    maas.*) MAAS_API_KEY="${key}" ;;
    partner-maas.*) PARTNER_API_KEY="${key}" ;;
    oidc-maas.*) OIDC_API_KEY="${key}" ;;
  esac
}

# Prints only the key on stdout; logs on stderr.
mint_key() {
  local base="$1" out key
  log "Minting API key via ${base}/maas-api/v1/api-keys (as $($OC whoami))…"
  out="$(
    curl -sSk \
      -H "Authorization: Bearer ${OC_TOKEN}" \
      -H "Content-Type: application/json" \
      -X POST \
      -d '{"name":"traffic-gen","expiresIn":"1d"}' \
      "${base}/maas-api/v1/api-keys"
  )"
  key="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("key") or d.get("apiKey") or "")' <<<"${out}")"
  printf '%s' "${key}"
}

# stdout: base|key|model_id|label
discover_gateway_targets() {
  local g base key
  local -a gw_list
  IFS=',' read -r -a gw_list <<<"${GATEWAYS}"
  for g in "${gw_list[@]}"; do
    g="$(echo "${g}" | xargs)"
    [[ -n "${g}" ]] || continue
    base="$(gateway_base "${g}")"
    key="$(key_for_gateway "${g}")"
    if [[ -z "${key}" ]]; then
      key="$(mint_key "${base}")"
      if [[ -z "${key}" ]]; then
        err "No API key for ${base} (mint failed); skipping"
        continue
      fi
      store_key "${base}" "${key}"
      log "Minted key for ${base} (prefix ${key:0:12}…)"
    fi

    curl -sSk -H "Authorization: Bearer ${OC_TOKEN}" "${base}/maas-api/v1/models" \
      | python3 -c '
import json, sys
base, key, filt_raw = sys.argv[1], sys.argv[2], sys.argv[3]
filt = [x.strip().lower() for x in filt_raw.split(",") if x.strip()]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data") or []:
    mid = m.get("id") or ""
    owned = m.get("owned_by") or ""
    disp = ((m.get("modelDetails") or {}).get("displayName") or "")
    if m.get("ready") is False:
        continue
    # Anthropic /v1/messages backends are flaky for bulk traffic; skip unless explicitly filtered.
    is_messages = (
        "messages" in mid.lower()
        or owned.endswith("/sim-messages")
        or owned.endswith("sim-messages")
    )
    if is_messages and not any("message" in f for f in filt):
        continue
    if filt:
        blob = f"{mid} {owned} {disp}".lower()
        if not any(f in blob for f in filt):
            continue
    label = owned or mid
    endpoint = "messages" if is_messages else "chat"
    print(f"{base}|{key}|{mid}|{label}|{endpoint}")
' "${base}" "${key}" "${MODELS_FILTER}" || true
  done
}

run_gateway() {
  mapfile -t TARGETS < <(discover_gateway_targets)
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    err "No ready models discovered on gateways: ${GATEWAYS}"
    exit 1
  fi

  log "Found ${#TARGETS[@]} model(s) via gateway; ${REQUESTS} request(s) each, max_tokens=${MAX_TOKENS}"
  local ok=0 fail=0 row base key mid label endpoint i code url body
  for row in "${TARGETS[@]}"; do
    IFS='|' read -r base key mid label endpoint <<<"${row}"
    endpoint="${endpoint:-chat}"
    if [[ "${endpoint}" == "messages" ]]; then
      url="${base}/v1/messages"
    else
      url="${base}/v1/chat/completions"
    fi
    log "${label} (id=${mid}) via ${url}"
    for ((i = 1; i <= REQUESTS; i++)); do
      body="{\"model\":\"${mid}\",\"messages\":[{\"role\":\"user\",\"content\":\"Traffic gen ${i}/${REQUESTS} for ${label}\"}],\"max_tokens\":${MAX_TOKENS}}"
      code="$(
        curl -sSk --http1.1 --max-time 60 -o "${OUT_DIR}/out.json" -w '%{http_code}' \
          -H "Authorization: Bearer ${key}" \
          -H "Content-Type: application/json" \
          -d "${body}" \
          "${url}" || true
      )"
      if [[ "${code}" == "200" ]]; then
        ok=$((ok + 1))
        printf '  [%s/%s] %s OK\n' "${i}" "${REQUESTS}" "${label}"
      else
        fail=$((fail + 1))
        printf '  [%s/%s] %s FAIL http=%s body=%s\n' "${i}" "${REQUESTS}" "${label}" "${code}" \
          "$(python3 -c "print(open('${OUT_DIR}/out.json').read()[:200])" 2>/dev/null || true)"
      fi
    done
  done
  log "Done via gateway: ok=${ok} fail=${fail}"
  [[ "${fail}" -eq 0 ]]
}

discover_direct_targets() {
  local ns_args=()
  if [[ -n "${NAMESPACES}" ]]; then
    local ns
    IFS=',' read -r -a ns_list <<<"${NAMESPACES}"
    for ns in "${ns_list[@]}"; do
      ns_args+=(-n "${ns}")
    done
  else
    ns_args=(-A)
  fi
  "${OC}" get llminferenceservice "${ns_args[@]}" -o json 2>/dev/null | python3 -c '
import json, sys
filt = [x for x in "'"${MODELS_FILTER}"'".split(",") if x]
data = json.load(sys.stdin)
for item in data.get("items") or []:
    meta = item.get("metadata") or {}
    name = meta.get("name") or ""
    ns = meta.get("namespace") or ""
    if filt and not any(f in name for f in filt):
        continue
    status = item.get("status") or {}
    ready = any(c.get("type")=="Ready" and c.get("status")=="True" for c in (status.get("conditions") or []))
    if not ready:
        continue
    model = ((item.get("spec") or {}).get("model") or {}).get("name") or name
    svc = f"{name}-kserve-workload-svc.{ns}.svc"
    print(f"{ns}/{name}|{model}|{svc}")
'
}

run_direct() {
  mapfile -t TARGETS < <(discover_direct_targets)
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    err "No Ready LLMInferenceService targets found"
    exit 1
  fi
  log "Found ${#TARGETS[@]} Ready model(s) (direct); ${REQUESTS} request(s) each"
  local PAYLOAD_B64 POD="maas-traffic-gen"
  PAYLOAD_B64="$(printf '%s\n' "${TARGETS[@]}" | base64 -w0 2>/dev/null || printf '%s\n' "${TARGETS[@]}" | base64)"
  log "Running in-cluster curl pod in ${RUNNER_NS}…"
  "${OC}" delete pod "${POD}" -n "${RUNNER_NS}" --ignore-not-found --wait=true &>/dev/null || true
  "${OC}" run "${POD}" -n "${RUNNER_NS}" --rm -i --restart=Never --image="${CURL_IMAGE}" \
    --env="REQUESTS=${REQUESTS}" \
    --env="MAX_TOKENS=${MAX_TOKENS}" \
    --env="TARGETS_B64=${PAYLOAD_B64}" \
    --command -- /bin/sh -c '
set -eu
echo "$TARGETS_B64" | base64 -d > /tmp/targets.txt
ok=0; fail=0
while IFS="|" read -r ns_name model_id svc; do
  [ -n "$ns_name" ] || continue
  echo "➜ $ns_name → https://${svc}:8000 (model=$model_id)"
  i=1
  while [ "$i" -le "$REQUESTS" ]; do
    code=$(curl -sSk -o /tmp/out.json -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"${model_id}\",\"messages\":[{\"role\":\"user\",\"content\":\"Traffic gen ${i}/${REQUESTS} for ${ns_name}\"}],\"max_tokens\":${MAX_TOKENS}}" \
      "https://${svc}:8000/v1/chat/completions" || echo "000")
    if [ "$code" = "200" ]; then
      ok=$((ok+1)); echo "  [${i}/${REQUESTS}] OK"
    else
      fail=$((fail+1)); echo "  [${i}/${REQUESTS}] FAIL http=$code $(head -c 160 /tmp/out.json 2>/dev/null || true)"
    fi
    i=$((i+1))
  done
done < /tmp/targets.txt
echo "➜ Done in-cluster: ok=${ok} fail=${fail}"
[ "$fail" -eq 0 ]
'
}

if [[ "${DIRECT}" -eq 1 ]]; then
  run_direct
else
  run_gateway
fi

#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Lab PostgreSQL in namespace "postgres" + maas-db-config Secret(s) for MaaS.
# Secret shape matches upstream:
#   https://github.com/opendatahub-io/models-as-a-service/blob/main/scripts/setup-database.sh
#   DB_CONNECTION_URL=postgresql://USER:PASS@HOST:5432/DB?sslmode=...
#
# Usage (from repo root):
#   ./infra/scripts/setup-postgres.sh
#   POSTGRES_PASSWORD='...' ./infra/scripts/setup-postgres.sh
#   DB_SSLMODE=require ./infra/scripts/setup-postgres.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${INFRA_DIR}/.." && pwd)"

POSTGRES_NS="${POSTGRES_NS:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-maas}"
POSTGRES_DB="${POSTGRES_DB:-maas}"
DB_SSLMODE="${DB_SSLMODE:-disable}"   # POC has no TLS on the pod; use require with external DBs
POSTGRES_HOST="${POSTGRES_HOST:-postgres.${POSTGRES_NS}.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Namespaces that may need maas-db-config (created only if the namespace already exists)
MAAS_DB_SECRET_NAMESPACES=(
  redhat-ai-gateway-infra
  odh-ai-gateway-infra
  redhat-ods-applications
  opendatahub
)

echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
echo "┃  POC PostgreSQL — ephemeral emptyDir (data lost on restart)     ┃"
echo "┃  For production use RDS / Crunchy / Azure + sslmode=require      ┃"
echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
echo ""
echo "Namespace: ${POSTGRES_NS}"
echo "Service:   ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo ""

#──────────────────────────────────────────────────────────────────────────────
# Credentials
#──────────────────────────────────────────────────────────────────────────────

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  if oc get secret postgres-creds -n "${POSTGRES_NS}" &>/dev/null; then
    POSTGRES_PASSWORD="$(oc get secret postgres-creds -n "${POSTGRES_NS}" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
    echo "Reusing password from existing Secret ${POSTGRES_NS}/postgres-creds"
  else
    POSTGRES_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
    echo "Generated new PostgreSQL password (stored in ${POSTGRES_NS}/postgres-creds)"
  fi
fi

oc get namespace "${POSTGRES_NS}" &>/dev/null || oc create namespace "${POSTGRES_NS}"
oc label namespace "${POSTGRES_NS}" \
  app.kubernetes.io/part-of=maas-demo-architectures \
  maas.demo/infra=postgres \
  --overwrite >/dev/null

oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
  namespace: ${POSTGRES_NS}
  labels:
    app: postgres
    app.kubernetes.io/part-of: maas-demo-architectures
    purpose: poc
type: Opaque
stringData:
  POSTGRES_USER: "${POSTGRES_USER}"
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
  POSTGRES_DB: "${POSTGRES_DB}"
EOF

#──────────────────────────────────────────────────────────────────────────────
# Postgres Deployment + Service
#──────────────────────────────────────────────────────────────────────────────

echo "Applying Postgres manifests…"
oc apply -k "${INFRA_DIR}/postgres"

echo "Waiting for deployment/postgres…"
oc wait -n "${POSTGRES_NS}" --for=condition=available deployment/postgres --timeout=180s

#──────────────────────────────────────────────────────────────────────────────
# maas-db-config (DB_CONNECTION_URL) — same key as upstream
#──────────────────────────────────────────────────────────────────────────────

# Percent-encode password for the URL (same approach as upstream setup-database.sh)
ENCODED_PASSWORD="$(printf '%s' "${POSTGRES_PASSWORD}" | od -An -tx1 | tr -d ' \n' | sed 's/../%&/g')"
DB_CONNECTION_URL="postgresql://${POSTGRES_USER}:${ENCODED_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=${DB_SSLMODE}"

create_maas_db_config() {
  local ns="$1"
  if ! oc get namespace "${ns}" &>/dev/null; then
    echo "  skip ${ns} (namespace not found)"
    return 0
  fi
  echo "  create/update ${ns}/maas-db-config"
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: maas-db-config
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: maas-demo-architectures
    maas.demo/infra: postgres
type: Opaque
stringData:
  DB_CONNECTION_URL: "${DB_CONNECTION_URL}"
EOF
}

echo "Writing maas-db-config Secret(s)…"
for ns in "${MAAS_DB_SECRET_NAMESPACES[@]}"; do
  create_maas_db_config "${ns}"
done

echo ""
echo "✅ Postgres ready"
echo "  Pod/Service:  ${POSTGRES_NS}/postgres"
echo "  Creds Secret: ${POSTGRES_NS}/postgres-creds"
echo "  MaaS Secret:  maas-db-config (DB_CONNECTION_URL) in existing infra/controller namespaces"
echo ""
echo "  Host used in URL: ${POSTGRES_HOST}"
echo "  sslmode:          ${DB_SSLMODE}"
echo ""
echo "If maas-api was already running, restart it to pick up the Secret:"
echo "  oc rollout restart deployment -n redhat-ai-gateway-infra -l app.kubernetes.io/name=maas-api"
echo "  oc rollout restart deployment -n odh-ai-gateway-infra -l app.kubernetes.io/name=maas-api"
echo ""
echo "Repo root (for demos): ${REPO_ROOT}"

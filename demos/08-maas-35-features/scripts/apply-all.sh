#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker (this script does not build images).
#
# Apply all Demo 08 tenants in order:
#   1. default (main) — deploy/overlays/demo08
#   2. partner — Gateway + AITenant + llm-partner catalog
#   3. oidc — Keycloak (unless skipped) + Gateway + AITenant + llm-oidc catalog
#
# Extra args are forwarded to apply-oidc-tenant.sh (e.g. --skip-keycloak).
#
# Usage (from repo root):
#   export MAAS_REPO=/path/to/models-as-a-service   # needed unless --skip-keycloak
#   ./demos/08-maas-35-features/scripts/apply-all.sh
#   ./demos/08-maas-35-features/scripts/apply-all.sh --skip-keycloak
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,18p' "$0"
      exit 0
      ;;
  esac
done

echo "=== Demo 08 — (1/3) default tenant ==="
"${SCRIPT_DIR}/apply-default-tenant.sh"

echo ""
echo "=== Demo 08 — (2/3) partner tenant ==="
# Default already applied above; do not pass --with-default.
"${SCRIPT_DIR}/apply-partner-tenant.sh"

echo ""
echo "=== Demo 08 — (3/3) OIDC tenant ==="
"${SCRIPT_DIR}/apply-oidc-tenant.sh" "$@"

echo ""
echo "Demo 08 — all three tenants applied."
echo "  default → https://maas.<domain>          (demo08-hybrid-catalog)"
echo "  partner → https://partner-maas.<domain>  (demo08-partner-catalog)"
echo "  oidc    → https://oidc-maas.<domain>     (demo08-oidc-catalog)"

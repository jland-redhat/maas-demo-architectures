#!/usr/bin/env bash
# Generate an htpasswd file for OpenShift HTPasswd IdP (lab only).
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker.
#
# Usage: ./htpasswd-sample-users.sh > /tmp/maas-demo-htpasswd
# Then create a Secret and configure oauth/cluster (see OpenShift docs).

set -euo pipefail

USERS=(alice:alicepass bob:bobpass chloe:chlopass dana:danapass)
OUT=""

for pair in "${USERS[@]}"; do
  user="${pair%%:*}"
  pass="${pair##*:}"
  if [[ -z "$OUT" ]]; then
    OUT="$(podman run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass")"
  else
    OUT+=$'\n'"$(podman run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass")"
  fi
done

printf '%s\n' "$OUT"

#!/usr/bin/env bash
# Usage: ./scripts/create-grafana-user.sh <login> <password> [Viewer|Editor|Admin]
# Creates a Grafana user with a role, using the admin credentials from .env.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

LOGIN="${1:?usage: $0 <login> <password> [role]}"
PASSWORD="${2:?usage: $0 <login> <password> [role]}"
ROLE="${3:-Viewer}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
AUTH="${GRAFANA_ADMIN_USER:-admin}:$GRAFANA_ADMIN_PASSWORD"

id="$(curl -fsS -u "$AUTH" -H 'Content-Type: application/json' \
  -X POST "$GRAFANA_URL/api/admin/users" \
  -d "{\"name\":\"$LOGIN\",\"login\":\"$LOGIN\",\"password\":\"$PASSWORD\"}" | sed -E 's/.*"id":([0-9]+).*/\1/')"

curl -fsS -u "$AUTH" -H 'Content-Type: application/json' \
  -X PATCH "$GRAFANA_URL/api/org/users/$id" -d "{\"role\":\"$ROLE\"}" >/dev/null

echo "Created user '$LOGIN' (id $id) with role $ROLE"

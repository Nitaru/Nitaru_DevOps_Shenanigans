#!/usr/bin/env bash
# Shared helpers for deploy.sh, rollback.sh and status.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="$ROOT_DIR/.deploy-state"
UPSTREAM_FILE="$ROOT_DIR/nginx/upstream/active.conf"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
PUBLIC_URL="${PUBLIC_URL:-http://localhost:8080}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

compose() { docker compose -f "$ROOT_DIR/docker-compose.yml" --env-file "$STATE_FILE" "$@"; }

# State file doubles as the compose env file (BLUE_VERSION / GREEN_VERSION)
load_state() {
  ACTIVE="none"
  BLUE_VERSION="none"
  GREEN_VERSION="none"
  # shellcheck source=/dev/null  # the state file is generated at runtime
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  return 0
}

save_state() {
  cat > "$STATE_FILE" <<STATE
ACTIVE=$ACTIVE
BLUE_VERSION=$BLUE_VERSION
GREEN_VERSION=$GREEN_VERSION
STATE
}

other_color() { [[ "$1" == "blue" ]] && echo green || echo blue; }

version_of() {
  if [[ "$1" == "blue" ]]; then echo "$BLUE_VERSION"; else echo "$GREEN_VERSION"; fi
}

wait_healthy() {
  local color="$1" container status
  container="$(compose ps -q "app-$color")"
  [[ -n "$container" ]] || die "app-$color is not running"
  log "Waiting for app-$color to become healthy (timeout ${HEALTH_TIMEOUT}s)..."
  for ((i = 0; i < HEALTH_TIMEOUT; i++)); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container")"
    if [[ "$status" == "healthy" ]]; then
      log "app-$color is healthy"
      return 0
    fi
    sleep 1
  done
  die "app-$color did not become healthy (last status: $status)"
}

# Hit the new container directly from inside the Docker network, before it gets traffic
smoke_test() {
  local color="$1" expected="$2" body
  log "Smoke testing app-$color..."
  body="$(compose run --rm --no-deps -T --entrypoint wget router -qO- "http://app-$color:5000/version")" \
    || die "smoke test request to app-$color failed"
  [[ "$body" == *"\"version\":\"$expected\""* ]] \
    || die "app-$color reports wrong version: $body"
  log "Smoke test passed: $body"
}

switch_traffic() {
  local color="$1"
  log "Switching traffic to $color"
  cat > "$UPSTREAM_FILE" <<CONF
upstream app_active {
    server app-$color:5000;
}
CONF
  if [[ -n "$(compose ps -q --status running router)" ]]; then
    # Validate first, then reload gracefully: open connections finish on the old workers
    compose exec -T router nginx -t -q
    compose exec -T router nginx -s reload
  else
    compose up -d router prometheus grafana
  fi
}

verify_public() {
  local expected="$1" body
  for ((i = 0; i < 10; i++)); do
    body="$(curl -fsS "$PUBLIC_URL/version" 2>/dev/null || true)"
    if [[ "$body" == *"\"version\":\"$expected\""* ]]; then
      log "Router is serving version $expected"
      return 0
    fi
    sleep 1
  done
  die "router is not serving version $expected (got: ${body:-nothing})"
}

# Best effort: mark the deployment on Grafana dashboards
annotate() {
  curl -fsS -u "admin:${GRAFANA_PASSWORD:-admin}" -H "Content-Type: application/json" \
    -X POST "$GRAFANA_URL/api/annotations" \
    -d "{\"text\": \"$1\", \"tags\": [\"deployment\"]}" >/dev/null 2>&1 || true
}

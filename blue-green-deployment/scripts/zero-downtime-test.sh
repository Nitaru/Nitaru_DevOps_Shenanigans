#!/usr/bin/env bash
# Usage: ./scripts/zero-downtime-test.sh <version>
# Fires requests at the router during a deployment and fails if any of them error.

source "$(dirname "$0")/lib.sh"

VERSION="${1:?usage: $0 <version>}"
RESULTS="$(mktemp)"

(
  while true; do
    curl -s -o /dev/null -w "%{http_code}\n" "$PUBLIC_URL/version" >> "$RESULTS"
    sleep 0.05
  done
) &
LOAD_PID=$!
trap 'kill $LOAD_PID 2>/dev/null || true; rm -f "$RESULTS"' EXIT

"$ROOT_DIR/scripts/deploy.sh" "$VERSION"
sleep 2
kill "$LOAD_PID"
wait "$LOAD_PID" 2>/dev/null || true

total="$(wc -l < "$RESULTS" | tr -d ' ')"
failed="$(grep -vc '^200$' "$RESULTS" || true)"
log "Requests during deploy: $total, failed: $failed"
[[ "$failed" -eq 0 ]] || die "downtime detected"

#!/usr/bin/env bash
# Shows which color is live and what version each slot runs.

source "$(dirname "$0")/lib.sh"

load_state
for color in blue green; do
  marker=" "
  [[ "$color" == "$ACTIVE" ]] && marker="*"
  printf "%s %-6s %s\n" "$marker" "$color" "$(version_of "$color")"
done
echo
curl -fsS "$PUBLIC_URL/version" 2>/dev/null && echo || echo "router not reachable at $PUBLIC_URL"

#!/usr/bin/env bash
# Usage: ./scripts/rollback.sh
# Sends traffic back to the previous color (which deploy.sh leaves running).

source "$(dirname "$0")/lib.sh"

load_state
[[ "$ACTIVE" != "none" ]] || die "nothing is deployed yet"
PREVIOUS="$(other_color "$ACTIVE")"
PREVIOUS_VERSION="$(version_of "$PREVIOUS")"
[[ "$PREVIOUS_VERSION" != "none" ]] || die "no previous version to roll back to"

log "Rolling back: $ACTIVE ($(version_of "$ACTIVE")) -> $PREVIOUS ($PREVIOUS_VERSION)"
compose up -d --no-deps "app-$PREVIOUS"
wait_healthy "$PREVIOUS"
switch_traffic "$PREVIOUS"
verify_public "$PREVIOUS_VERSION"

ACTIVE="$PREVIOUS"
save_state
annotate "Rolled back to $PREVIOUS_VERSION ($PREVIOUS)"
log "Rollback complete"

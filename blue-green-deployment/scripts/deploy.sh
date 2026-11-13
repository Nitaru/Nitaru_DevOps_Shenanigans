#!/usr/bin/env bash
# Usage: ./scripts/deploy.sh <version>
#
# Builds <version>, starts it in the idle color, health checks and smoke tests it,
# then switches the router to it. The previous color keeps running for instant rollback.

source "$(dirname "$0")/lib.sh"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: $0 <version>"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "version may only contain letters, numbers, '.', '_' and '-'"

load_state
if [[ "$ACTIVE" == "none" ]]; then
  TARGET="blue"
else
  TARGET="$(other_color "$ACTIVE")"
fi
log "Active: $ACTIVE ($(version_of "$ACTIVE")) -> deploying $VERSION to $TARGET"

log "Building bluegreen-app:$VERSION"
docker build -q -t "bluegreen-app:$VERSION" --build-arg "APP_VERSION=$VERSION" "$ROOT_DIR/app" >/dev/null

if [[ "$TARGET" == "blue" ]]; then BLUE_VERSION="$VERSION"; else GREEN_VERSION="$VERSION"; fi
save_state

compose up -d redis
compose up -d --no-deps --force-recreate "app-$TARGET"

# If either check fails the script exits here and the router is never touched
wait_healthy "$TARGET"
smoke_test "$TARGET" "$VERSION"

switch_traffic "$TARGET"
verify_public "$VERSION"

ACTIVE="$TARGET"
save_state
annotate "Deployed $VERSION to $TARGET"
log "Done. $TARGET ($VERSION) is live. Previous color kept running for rollback: ./scripts/rollback.sh"

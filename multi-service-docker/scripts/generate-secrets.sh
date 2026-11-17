#!/usr/bin/env bash
# Creates random passwords for the Docker secrets (only if they don't exist yet).
#
# Permissions matter on Linux. Compose bind-mounts each secret file with the host file's owner and mode, and
# the containers read it as non-root users (mongo as uid 999, the API as uid 1000), so a 600 file owned by you
# is unreadable inside them ("Permission denied"). Docker Desktop on macOS hides this, a Linux server does not.
# So the files are world-readable, and the directory holding them is private to you (700): other users on the
# host cannot even list it, while the containers reach the files through the bind mount.
set -euo pipefail
cd "$(dirname "$0")/../secrets"

chmod 700 .
for name in mongo_password redis_password; do
  if [[ -f "$name.txt" ]]; then
    echo "secrets/$name.txt already exists, skipping"
  else
    openssl rand -hex 24 > "$name.txt"
    echo "created secrets/$name.txt"
  fi
  chmod 644 "$name.txt"
done

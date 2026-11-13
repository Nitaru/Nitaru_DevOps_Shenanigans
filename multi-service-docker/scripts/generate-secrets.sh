#!/usr/bin/env bash
# Creates random passwords for the Docker secrets (only if they don't exist yet).
set -euo pipefail
cd "$(dirname "$0")/../secrets"

for name in mongo_password redis_password; do
  if [[ -f "$name.txt" ]]; then
    echo "secrets/$name.txt already exists, skipping"
  else
    openssl rand -hex 24 > "$name.txt"
    chmod 600 "$name.txt"
    echo "created secrets/$name.txt"
  fi
done

#!/usr/bin/env bash
# End-to-end test of the claims in the README: health, caching, persistence, network isolation,
# secrets handling, non-root containers and log rotation. Runs on its own project name and port.
# KEEP=1 leaves the stack running afterwards.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export COMPOSE_PROJECT_NAME=msdtest PROXY_PORT=18081
URL=http://localhost:$PROXY_PORT
dc() { docker compose "$@"; }

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
retry() { local secs=$1; shift; for _ in $(seq 1 "$secs"); do "$@" && return 0; sleep 1; done; return 1; }
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
post_note() { curl -s -m 5 -X POST "$URL/api/notes" -H 'Content-Type: application/json' -d "{\"text\":\"$1\"}"; }
source_of_list() { curl -s -m 5 "$URL/api/notes" | jq -r .source; }

cleanup() { [[ ${KEEP:-0} == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT

echo "build and start"
dc down -v --remove-orphans >/dev/null 2>&1
./scripts/generate-secrets.sh >/dev/null
docker build -q -t msd/node-base:1.0 base/node-base >/dev/null
if dc up --build -d >/dev/null 2>&1; then ok "stack builds and starts"; else bad "stack builds and starts"; dc logs --tail 30; exit 1; fi

healthy_count() {
  local n=0 id
  for id in $(dc ps -q); do [[ $(docker inspect -f '{{.State.Health.Status}}' "$id") == healthy ]] && n=$((n + 1)); done
  echo "$n"
}
all_healthy()  { [[ $(healthy_count) -eq 5 ]]; }
container()    { dc ps -q "$1"; }
expect_code()  { local want=$1; shift; [[ $(code "$@") == "$want" ]]; }
list_source()  { [[ $(source_of_list) == "$1" ]]; }
json_note()    { curl -s -m 5 -X POST "$URL/api/notes" -H 'Content-Type: application/json' -d "$1" -o /dev/null -w '%{http_code}'; }

echo "health and routing"
check "all five services become healthy"        retry 180 all_healthy
web_root()     { curl -s -m 5 "$URL/" | grep -qi '<div id="root"'; }
api_health()   { [[ $(curl -s -m 5 "$URL/api/health" | jq -r .status) == ok ]]; }
check "the web app is served at /"              web_root
check "the API answers through the proxy and reaches Mongo and Redis" api_health

echo "API behaviour and caching"
unique="note-$$-$RANDOM"
created=$(post_note "$unique")
id=$(jq -r ._id <<<"$created")
created_ok()   { [[ $(jq -r .text <<<"$created") == "$unique" && -n $id && $id != null ]]; }
empty_rejected() { [[ $(json_note '{"text":"  "}') == 400 ]]; }
check "POST /api/notes creates a note"          created_ok
check "an empty note is rejected (400)"         empty_rejected
check "the first read after a write comes from the database" list_source database
check "the second read comes from Redis"        list_source cache
post_note "another-$unique" >/dev/null
check "a write invalidates the cache"           list_source database
check "DELETE of a malformed id is rejected (400)" expect_code 400 -X DELETE "$URL/api/notes/nope"
check "DELETE of an unknown id returns 404"     expect_code 404 -X DELETE "$URL/api/notes/000000000000000000000000"
check "DELETE of an existing note returns 204"  expect_code 204 -X DELETE "$URL/api/notes/$id"

echo "network isolation"
published() { docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{if $b}}{{$p}} {{end}}{{end}}' "$(container "$1")"; }
only_proxy_publishes() {
  [[ -n $(published proxy) ]] || return 1
  local s; for s in web api mongo redis; do [[ -z $(published $s) ]] || return 1; done
}
mongo_unreachable_from_host() { ! (echo > /dev/tcp/127.0.0.1/27017) 2>/dev/null; }
mongo_has_no_internet() { ! dc exec -T mongo bash -c 'timeout 4 bash -c "echo > /dev/tcp/1.1.1.1/80"' 2>/dev/null; }
mongo_can_reach_redis() { dc exec -T mongo bash -c 'timeout 4 bash -c "echo > /dev/tcp/redis/6379"' 2>/dev/null; }
check "only the proxy publishes a port"         only_proxy_publishes
check "MongoDB is not reachable from the host"  mongo_unreachable_from_host
check "control: containers on the backend network can reach each other" mongo_can_reach_redis
check "the backend network is internal (Mongo cannot reach the internet)" mongo_has_no_internet

echo "secrets and users"
mongo_secret=$(cat secrets/mongo_password.txt); redis_secret=$(cat secrets/redis_password.txt)
lacks_secrets() { ! grep -q -e "$mongo_secret" -e "$redis_secret"; }
# shellcheck disable=SC2046  # one argument per container id is the point
inspect_clean() { docker inspect $(dc ps -q) | lacks_secrets; }
logs_clean()    { dc logs 2>&1 | lacks_secrets; }
history_clean() { { docker history --no-trunc msd/api:1.0; docker history --no-trunc msd/web:1.0; } | lacks_secrets; }
secrets_mounted() { dc exec -T api ls /run/secrets | grep -q mongo_password; }
nonroot()       { [[ $(dc exec -T "$1" id -u | tr -d '\r') != 0 ]]; }
leak_detected() { ! echo "x $mongo_secret y" | lacks_secrets; }
check "control: the secret scan does detect a password when one is present" leak_detected
check "the passwords are not in any container's configuration" inspect_clean
check "the passwords are not in the container logs" logs_clean
check "the passwords are not in the image layers" history_clean
check "the secrets are mounted as files in /run/secrets" secrets_mounted
check "the API runs as a non-root user"         nonroot api
check "the web container runs as a non-root user" nonroot web

echo "logging and image size"
logs_rotated() {
  local s cfg
  for s in proxy web api mongo redis; do
    cfg=$(docker inspect -f '{{.HostConfig.LogConfig.Config}}' "$(container $s)")
    [[ $cfg == *max-size:10m* && $cfg == *max-file:3* ]] || return 1
  done
}
check "every service rotates logs at 10m, 3 files" logs_rotated
# Same measure as `docker images` (what the README quotes), converted to MB.
image_mb() { docker images --format '{{.Size}}' "$1" | awk '{v=$1; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v); m=(u=="GB")?1000:(u=="kB")?0.001:1; printf "%d", v*m}'; }
web_mb=$(image_mb msd/web:1.0); base_mb=$(image_mb msd/node-base:1.0)
check "the multi-stage web image ($web_mb MB) is under half the size of its build base ($base_mb MB)" test "$web_mb" -gt 0 -a "$web_mb" -lt $((base_mb / 2))

echo "resilience and persistence"
dc restart api >/dev/null 2>&1
check "the proxy finds the API again after it restarts" retry 60 api_health
keep="persist-$$-$RANDOM"; post_note "$keep" >/dev/null
note_present() { curl -s -m 5 "$URL/api/notes" | jq -e --arg t "$keep" 'any(.notes[]; .text == $t)'; }
dc down >/dev/null 2>&1
dc up -d >/dev/null 2>&1
check "the stack is healthy again after down and up" retry 180 all_healthy
check "the note survives down and up (volumes)"  retry 30 note_present

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || { dc logs --tail 20; exit 1; }

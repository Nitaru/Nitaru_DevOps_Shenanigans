#!/usr/bin/env bash
# End-to-end test: builds the stack, then checks discovery, load balancing and failure handling.
# Uses its own project name and ports, so it can run next to anything else on this machine.
# KEEP=1 leaves the stack running afterwards.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export COMPOSE_PROJECT_NAME=sdtest GATEWAY_PORT=18080 CONSUL_PORT=18500 CONSUL_DNS_PORT=18600
GW=http://localhost:$GATEWAY_PORT
CONSUL=http://localhost:$CONSUL_PORT
dc() { docker compose "$@"; }

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
retry() { local secs=$1; shift; for _ in $(seq 1 "$secs"); do "$@" && return 0; sleep 1; done; return 1; }
code() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s -m 5 "$@"; }

cleanup() {
  [[ ${KEEP:-0} == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1
}
trap cleanup EXIT

echo "build and start"
dc down -v --remove-orphans >/dev/null 2>&1
if dc up --build -d >/dev/null 2>&1; then ok "stack builds and starts"; else bad "stack builds and starts"; dc logs --tail 30; exit 1; fi

# healthy_count <service>: instances Consul considers passing
healthy_count() { body "$CONSUL/v1/health/service/$1?passing=true" | jq 'length'; }
has_n()         { [[ $(healthy_count "$1") -ge $2 ]]; }
exactly_n()     { [[ $(healthy_count "$1") -eq $2 ]]; }
status_is()     { [[ $(code "$GW/$1") == "$2" ]]; }
all_listed()    { body "$GW/services" | jq -e 'has("service-a") and has("service-b") and has("service-c")'; }
info_is()       { body "$GW/service-$1/info" | jq -e --arg n "Service $2" '.service == $n'; }
distinct_backends() {
  for _ in $(seq 1 12); do
    curl -s -m 5 -D - -o /dev/null "$GW/service-a/info" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-served-by"{print $2}'
  done | sort -u | wc -l
}
spread_over_three() { [[ $(distinct_backends) -eq 3 ]]; }

echo "discovery"
check "Consul answers on its API"              retry 30 curl -fs "$CONSUL/v1/status/leader"
for s in a b c; do
  check "service-$s registers and passes its health check" retry 60 has_n "service-$s" 1
done
check "gateway lists all three services"       all_listed
check "GET /service-a/info is routed to Service A" info_is a A
check "GET /service-b/info is routed to Service B" info_is b B
check "GET /service-c/info is routed to Service C" info_is c C
check "an unknown service returns 404"         status_is nope/info 404

echo "load balancing"
dc up -d --scale service-a=3 --no-recreate >/dev/null 2>&1
check "three instances of service-a register"  retry 60 has_n service-a 3
check "requests are spread over all three instances" spread_over_three
dc up -d --scale service-a=1 --no-recreate >/dev/null 2>&1
check "scaling back to one deregisters the others" retry 60 exactly_n service-a 1

echo "failure handling"
dc stop service-c >/dev/null 2>&1
check "a stopped service deregisters itself and the gateway returns 404" retry 30 status_is service-c/info 404
dc start service-c >/dev/null 2>&1
check "it comes back when restarted"           retry 60 status_is service-c/info 200
# A killed process cannot deregister; only Consul's HTTP health check (10s interval) can notice.
dc kill service-b >/dev/null 2>&1
check "a killed service is noticed by the health check and dropped (<45s)" retry 45 status_is service-b/info 404
dc start service-b >/dev/null 2>&1
check "it comes back after a restart"          retry 60 status_is service-b/info 200
dc stop consul >/dev/null 2>&1
check "with Consul down the gateway returns 503, not a hang" status_is service-a/info 503
dc start consul >/dev/null 2>&1
check "when Consul is back, routing recovers without restarting anything else" retry 90 status_is service-a/info 200

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || { dc logs --tail 20 gateway; exit 1; }

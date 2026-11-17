#!/usr/bin/env bash
# Tests the monitoring stack: rule unit tests (promtool), then the running stack end to end:
# service discovery, recording rules, the custom exporter, Loki, Grafana provisioning and auth,
# the user script, and a real alert firing and resolving.
#
# The compose project must be named "monitoring" (Prometheus and Promtail select that network and
# project), so this cannot run next to a copy of the stack you already started. It refuses to touch
# existing data unless FORCE=1. KEEP=1 leaves the stack running afterwards.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export NGINX_PORT=18082 PROMETHEUS_PORT=19090 GRAFANA_PORT=13000
PROM=http://localhost:$PROMETHEUS_PORT
GRAF=http://localhost:$GRAFANA_PORT
PROM_IMAGE=prom/prometheus:v2.55.1
dc() { docker compose "$@"; }

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
retry() { local secs=$1; shift; for _ in $(seq 1 "$secs"); do "$@" && return 0; sleep 1; done; return 1; }

# ---------------------------------------------------------------- rules (no stack needed)
promtool() { docker run --rm -v "$PWD/prometheus:/etc/prometheus" -w /etc/prometheus --entrypoint promtool "$PROM_IMAGE" "$@"; }
rules_valid()    { promtool check config /etc/prometheus/prometheus.yml; }
rules_tested()   { promtool test rules tests/rules.test.yml; }
echo "rules"
check "prometheus.yml and the rule files are valid"      rules_valid
check "alert and recording rules pass their unit tests"  rules_tested

# ---------------------------------------------------------------- start the stack
if [[ -n $(docker volume ls -q --filter name=^monitoring_) || -n $(dc ps -aq 2>/dev/null) ]] && [[ ${FORCE:-0} != 1 ]]; then
  echo "A 'monitoring' stack or its volumes already exist. This test deletes them (down -v)." >&2
  echo "Re-run with FORCE=1 if you are sure, or remove them yourself." >&2
  exit 2
fi
made_env=0
if [[ ! -f .env ]]; then
  printf 'GRAFANA_ADMIN_USER=admin\nGRAFANA_ADMIN_PASSWORD=test-%s\nALERT_EMAIL=test@example.com\n' "$RANDOM$RANDOM" > .env
  made_env=1
fi
set -a; source .env; set +a
AUTH="${GRAFANA_ADMIN_USER:-admin}:$GRAFANA_ADMIN_PASSWORD"

cleanup() {
  docker rm -f sdprobe >/dev/null 2>&1
  if [[ ${KEEP:-0} != 1 ]]; then dc down -v --remove-orphans >/dev/null 2>&1; (( made_env )) && rm -f .env; fi
}
trap cleanup EXIT

echo "build and start"
dc down -v --remove-orphans >/dev/null 2>&1
if dc up --build -d >/dev/null 2>&1; then ok "stack builds and starts"; else bad "stack builds and starts"; dc logs --tail 30; exit 1; fi

prom_ready()    { [[ $(curl -s -m 5 -o /dev/null -w '%{http_code}' "$PROM/-/ready") == 200 ]]; }
grafana_ready() { [[ $(curl -s -m 5 "$GRAF/api/health" | jq -r .database) == ok ]]; }
check "Prometheus becomes ready"   retry 90 prom_ready
check "Grafana becomes ready"      retry 120 grafana_ready

pq()        { curl -s -m 10 -G "$PROM/api/v1/query" --data-urlencode "query=$1"; }
pq_has()    { pq "$1" | jq -e '.data.result | length > 0'; }
gget()      { curl -s -m 10 -u "$AUTH" "$GRAF$1"; }
gcode()     { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }

echo "prometheus"
flags_ok() {
  curl -s "$PROM/api/v1/status/flags" | jq -e '.data["storage.tsdb.retention.time"] == "15d" and .data["storage.tsdb.retention.size"] == "5GiB"'
}
check "retention is 15 days or 5 GB, as documented (Prometheus reports 5GB as 5GiB)" flags_ok
expected_jobs="app nginx-exporter node-exporter prometheus redis-exporter shop-exporter"
up_jobs() { curl -s "$PROM/api/v1/targets" | jq -r '.data.activeTargets[] | select(.health == "up") | .labels.job' | sort | tr '\n' ' ' | sed 's/ $//'; }
all_targets_up() { [[ $(up_jobs) == "$expected_jobs" ]]; }
check "all six targets are discovered and up (no hard-coded targets)" retry 120 all_targets_up
probe_up()   { curl -s "$PROM/api/v1/targets" | jq -e '.data.activeTargets[] | select(.labels.instance == "sdprobe" and .health == "up")'; }
probe_gone() { ! curl -s "$PROM/api/v1/targets" | jq -e '.data.activeTargets[] | select(.labels.instance == "sdprobe")' >/dev/null; }
docker run -d --name sdprobe --network monitoring_default --label prometheus.scrape=true --label prometheus.port=9100 prom/node-exporter:v1.8.2 >/dev/null 2>&1
check "a new labelled container is scraped within 45 s, without editing any config" retry 45 probe_up
docker rm -f sdprobe >/dev/null 2>&1
check "and it disappears from the targets again within 45 s" retry 45 probe_gone

echo "metrics, recording rules and the custom exporter"
check "the app exports request-latency histograms"       retry 90 pq_has 'http_request_duration_seconds_count{job="app"}'
check "the recording rule job:http_requests:rate5m has data" retry 150 pq_has 'job:http_requests:rate5m{job="app"}'
check "the recording rule for CPU utilisation has data"  retry 150 pq_has 'instance:node_cpu_utilisation:ratio'
check "the nginx exporter reports"                       retry 60 pq_has 'nginx_connections_active'
check "the Redis exporter reports Redis as up"           retry 60 pq_has 'redis_up == 1'
check "the custom shop exporter reports Redis as reachable" retry 60 pq_has 'shop_exporter_redis_up == 1'
check "the custom exporter reads real business data (revenue > 0)" retry 120 pq_has 'shop_revenue_dollars_total > 0'

echo "logs (Loki through Grafana)"
# log queries must be range queries; the default window is the last hour
loki() { curl -s -m 10 -u "$AUTH" -G "$GRAF/api/datasources/proxy/uid/loki/loki/api/v1/query_range" --data-urlencode "query=$1" --data-urlencode limit=1; }
loki_has() { loki "$1" | jq -e '.data.result | length > 0'; }
check "Promtail ships the app's logs to Loki"            retry 120 loki_has '{service="app"}'
check "Promtail ships nginx's logs to Loki"              retry 120 loki_has '{service="nginx"}'
check "the level in JSON logs becomes a label"           retry 120 loki_has '{service="app", level=~".+"}'
loki_retention() { curl -s -m 10 -u "$AUTH" "$GRAF/api/datasources/proxy/uid/loki/config" | grep -q -E 'retention_period: 1w|retention_period: 168h'; }
check "Loki's effective retention is 7 days"             loki_retention

echo "grafana"
anonymous_refused() { [[ $(gcode "$GRAF/api/dashboards/home") == 401 ]]; }
check "anonymous access is disabled (401 without credentials)" anonymous_refused
ds_ok() { [[ $(gget "/api/datasources/uid/$1/health" | jq -r .status) == OK ]]; }
check "the Prometheus data source is provisioned and healthy" ds_ok prometheus
check "the Loki data source is provisioned and healthy"  ds_ok loki
has_dash() { curl -s -m 10 -u "$AUTH" -G "$GRAF/api/search" --data-urlencode "query=$1" | jq -e --arg t "$1" 'any(.[]; .title == $t)'; }
check "the System Overview dashboard is provisioned"     has_dash "System Overview"
check "the Shop Application dashboard is provisioned"    has_dash "Shop Application"
has_rule() { gget /api/v1/provisioning/alert-rules | jq -e --arg u "$1" 'any(.[]; .uid == $u)'; }
check "the 'error rate' alert rule is provisioned"       has_rule shop-high-error-rate
check "the 'API down' alert rule is provisioned"         has_rule shop-api-down
has_contact() { gget /api/v1/provisioning/contact-points | jq -e 'any(.[]; .name == "email")'; }
check "the email contact point is provisioned"           has_contact

echo "users"
GRAFANA_URL=$GRAF ./scripts/create-grafana-user.sh testviewer 'a-Strong-pw-123' Viewer >/dev/null 2>&1
viewer_role() { curl -s -m 10 -u testviewer:'a-Strong-pw-123' "$GRAF/api/user/orgs" | jq -e '.[0].role == "Viewer"'; }
viewer_cannot_admin() { [[ $(gcode -u testviewer:'a-Strong-pw-123' -X POST -H 'Content-Type: application/json' -d '{"login":"x","password":"yyyyyyyy"}' "$GRAF/api/admin/users") == 403 ]]; }
check "create-grafana-user.sh creates a user that can log in with the Viewer role" viewer_role
check "a Viewer cannot create users"                     viewer_cannot_admin
bad_login() { [[ $(gcode -u admin:wrong-password "$GRAF/api/user") == 401 ]]; }
check "a wrong password is rejected"                     bad_login

echo "alerting: stop the API and watch the alerts fire, then recover"
prom_alert() { curl -s "$PROM/api/v1/alerts" | jq -e --arg n "$1" --arg s "$2" 'any(.data.alerts[]; .labels.alertname == $n and .state == $s)'; }
prom_alert_gone() { curl -s "$PROM/api/v1/alerts" | jq -e --arg n "$1" 'all(.data.alerts[]; .labels.alertname != $n)'; }
grafana_rule_state() { gget /api/prometheus/grafana/api/v1/rules | jq -e --arg s "$1" '[.data.groups[].rules[] | select(.name == "Shop API down") | .state] | any(. == $s)'; }
dc stop app >/dev/null 2>&1
check "Prometheus fires ShopApiMissing (the container vanishes from discovery)" retry 200 prom_alert ShopApiMissing firing
check "Grafana's 'Shop API down' rule fires too"         retry 200 grafana_rule_state firing
dc start app >/dev/null 2>&1
check "ShopApiMissing resolves once the API is back"     retry 150 prom_alert_gone ShopApiMissing

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 )) || { dc logs --tail 15 prometheus grafana; exit 1; }

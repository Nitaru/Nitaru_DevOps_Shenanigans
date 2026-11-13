# Monitoring with Prometheus and Grafana

A solution to the [roadmap.sh Monitoring with Prometheus and Grafana project](https://roadmap.sh/projects/monitoring-prometheus-grafana):
a full monitoring stack for a server and the application running on it. It covers metrics,
dashboards, alerting and logs, including all of the advanced goals.

```
                       ┌──────────── monitored server ─────────────┐
 users ──:8080──▶ nginx ──▶ app (Node.js, instrumented) ──▶ redis   │
                    │        │                              │       │
            nginx-exporter   │ /metrics          redis-exporter  shop-exporter (custom)
                    │        │                              │       │     node-exporter
                    └────────┴──────────┬───────────────────┴───────┴──────┘
                                        │ scrape (found via Docker service discovery)
                                  ┌─────▼──────┐  rules: recording + alerting
                                  │ Prometheus │
                                  └─────┬──────┘
   container logs ─▶ Promtail ─▶ Loki   │
                                  ┌─────▼──────┐  dashboards, alerts → email / Slack
                                  │  Grafana   │  :3000
                                  └────────────┘
```

## What's included

### The application being monitored
- **`app/`**: a small Node.js/Express "shop" API, instrumented with `prom-client`. It records request latency histograms per route and status, orders per product, order value and payment failures, plus default Node.js process metrics. It randomly makes some requests slow or failing (5xx) so there's something interesting to watch.
- **`nginx`**: reverse proxy in front of the app, with JSON access logs and `stub_status`.
- **`redis`**: stores orders.
- **`load-generator`**: keeps sending traffic so the dashboards are never empty.

### Prometheus ([`prometheus/`](prometheus))
- **Scrape config**: 15s scrape and evaluation interval, 10s timeout.
- **Retention**: `--storage.tsdb.retention.time=15d` and `--storage.tsdb.retention.size=5GB` (whichever limit is hit first).
- **Exporters**:
  | Exporter | Metrics |
  |----------|---------|
  | `node-exporter` | System: CPU, memory, disk, network, load |
  | `nginx-exporter` | Nginx connections and requests |
  | `redis-exporter` | Redis memory, commands, clients |
  | `shop-exporter` | **Custom exporter** ([`custom-exporter/exporter.py`](custom-exporter/exporter.py)) that reads business data from Redis: revenue, pending orders backlog, orders per product |
- **Service discovery**: no hard-coded targets. Prometheus uses `docker_sd_configs` to find every container labelled `prometheus.scrape=true` and scrapes the port given in `prometheus.port`. Add a labelled container and it's monitored within 15s.
- **Recording rules** ([`rules/recording.yml`](prometheus/rules/recording.yml)): request rate, error ratio, p95 latency, CPU/memory/disk utilisation are pre-computed, so dashboards and alerts stay fast.
- **Alerting rules** ([`rules/alerts.yml`](prometheus/rules/alerts.yml)): `TargetDown`, `ShopApiMissing`, `HighErrorRate`, `HighLatency`, `OrderBacklogGrowing`, `HighCpuUsage`, `HighMemoryUsage`, `DiskAlmostFull`.

### Grafana ([`grafana/`](grafana))
Everything is provisioned from files, so there's no clicking around after startup:
- **Data sources**: Prometheus and Loki.
- **Dashboards**:
  - **System Overview**: CPU (by mode), load, memory, disk usage per mount, disk and network I/O.
  - **Shop Application**: request rate, error rate, p50/p95/p99 latency, revenue, orders per product, fulfilment backlog, nginx and Redis panels, and a live panel of warning/error logs from Loki.
- **Alerting**: an email contact point (address from `.env`, with a Slack example ready to uncomment), a notification policy, and Grafana-managed alert rules for error rate and the API being down.
- **Authentication**: admin credentials come from `.env`, anonymous access and sign-up are disabled, and [`scripts/create-grafana-user.sh`](scripts/create-grafana-user.sh) creates users with a `Viewer`/`Editor`/`Admin` role.

### Logs
**Promtail** reads the logs of every container in the stack through the Docker API and ships them to **Loki** (7-day retention). The app and nginx log JSON, so `level` becomes a label. In Grafana → Explore → Loki, try:

```logql
{service="app", level="warn"}
{service="nginx"} | json | status >= 500
```

## Run it

Requires Docker with Compose. On a fresh Linux server (e.g. an Ubuntu droplet on DigitalOcean), install Docker first with `curl -fsSL https://get.docker.com | sh`.

```bash
cp .env.example .env      # then set GRAFANA_ADMIN_PASSWORD (and ALERT_EMAIL / SMTP_* for emails)
docker compose up --build -d
```

| URL | What |
|-----|------|
| <http://localhost:8080/api/products> | The app (through nginx) |
| <http://localhost:9090/targets> | Prometheus targets (all discovered automatically) |
| <http://localhost:9090/alerts> | Prometheus alerts |
| <http://localhost:3000> | Grafana (log in with the credentials from `.env`) |

On a server, replace `localhost` with the server IP, and firewall ports 9090/3000 or put them behind a VPN or reverse proxy with TLS.

Create a read-only user for a teammate:

```bash
./scripts/create-grafana-user.sh alice 'a-strong-password' Viewer
```

## Try the alerts

```bash
docker compose stop app
# after ~1 minute ShopApiMissing fires in Prometheus (localhost:9090/alerts)
# and Grafana's "Shop API down" rule notifies the email contact point
docker compose start app
```

## Clean up

```bash
docker compose down        # keep data
docker compose down -v     # also delete Prometheus, Loki, Grafana and Redis data
```

> **Note:** on Docker Desktop (macOS/Windows), node-exporter reports on Docker's Linux VM rather than your laptop. On a Linux server it reports on the server itself.

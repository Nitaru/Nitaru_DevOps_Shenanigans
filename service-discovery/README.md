# Service Discovery with Consul

A solution to the [roadmap.sh Service Discovery project](https://roadmap.sh/projects/service-discovery):
three dummy services that register themselves with Consul, and an API gateway that discovers
and routes to them through Consul.

```
                 ┌──────────────┐
  client ──────▶ │  API Gateway │ ── 1. "where is service-b?" ──▶ ┌────────┐
   :8080         │   (Flask)    │ ◀─ 2. healthy instances ─────── │ Consul │ :8500 (UI/API)
                 └──────┬───────┘                                 └────▲───┘ :8600 (DNS)
                        │ 3. proxy request                             │
          ┌─────────────┼─────────────┐                     register on startup
          ▼             ▼             ▼                     + /health checks
     ┌─────────┐   ┌─────────┐   ┌─────────┐                           │
     │Service A│   │Service B│   │Service C│ ──────────────────────────┘
     └─────────┘   └─────────┘   └─────────┘
```

## Components

| Component | Path | What it does |
|-----------|------|--------------|
| Dummy services | `services/` | One Flask app run three times (`SERVICE_NAME` = `service-a`/`b`/`c`). Exposes `/info` (service name + timestamp) and `/health`. Registers with Consul on startup (with an HTTP health check) and deregisters on shutdown. |
| API Gateway | `gateway/` | Single entry point. For `/<service>/<path>` it asks Consul's health API for **passing** instances, round-robins between them, and proxies the request. |
| Consul | `docker-compose.yml` | Runs in dev mode; stores the service registry and health status. |

## Run it

Requires Docker with Compose.

```bash
docker compose up --build -d
```

Then:

```bash
# Call services through the gateway
curl localhost:8080/service-a/info
curl localhost:8080/service-b/info
curl localhost:8080/service-c/info

# See what the gateway discovered
curl localhost:8080/services
```

Example response:

```json
{"id": "service-a-3f2c1d9e8b7a", "service": "Service A", "timestamp": "2026-11-14T00:10:00.123456+00:00"}
```

Consul UI: <http://localhost:8500>

## Exploring Consul directly

```bash
# HTTP API
curl localhost:8500/v1/catalog/services
curl "localhost:8500/v1/health/service/service-a?passing=true"

# DNS interface
dig @127.0.0.1 -p 8600 service-a.service.consul SRV
```

## Try it out

**Scale a service** — the gateway load-balances across instances (check the `X-Served-By` header and `id` field):

```bash
docker compose up -d --scale service-a=3
for i in 1 2 3 4 5 6; do curl -s localhost:8080/service-a/info; echo; done
```

**Stop a service** — it deregisters and the gateway returns `404 No healthy instances`:

```bash
docker compose stop service-c
curl -i localhost:8080/service-c/info
docker compose start service-c
```

## Clean up

```bash
docker compose down
```

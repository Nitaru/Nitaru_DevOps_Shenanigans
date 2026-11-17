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

## Test it

```bash
scripts/test.sh     # builds the stack on its own ports (18080, 18500) and runs 19 checks, about 40 seconds
KEEP=1 scripts/test.sh   # leave the stack running afterwards
```

It checks discovery (all three services register and pass their health check, the gateway lists them and
routes to the right one), load balancing (scale `service-a` to three and confirm requests reach all three,
then scale back and confirm the extra instances deregister) and failure handling:

| Failure | Expected result | How it is detected |
|---|---|---|
| `docker compose stop service-c` | gateway answers 404 | the service deregisters itself on SIGTERM |
| `docker compose kill service-b` | gateway answers 404 within 45 s | nothing deregisters, so only Consul's HTTP health check (10 s interval) notices |
| Consul stopped | gateway answers 503 instead of hanging | the gateway fails the lookup and says so |
| Consul started again | routing works again with no other restarts | see below |

The ports are configurable (`GATEWAY_PORT`, `CONSUL_PORT`, `CONSUL_DNS_PORT`, defaults 8080, 8500, 8600),
which is how the test runs next to other projects that use 8080.

Not tested: the DNS interface on port 8600 (the `dig` example above), and anything about a multi-node Consul cluster.

## Things I checked, and what I got wrong

- **My first test run reported 15 passed and silently skipped three checks.** macOS ships bash 3.2, which
  has no `${var^^}`; the expansion failed inside a loop and the loop body never ran, so those checks were
  neither passed nor failed. I rewrote the test as plain functions and ran a sabotaged copy with three
  wrong expectations to confirm that each one reports FAIL.
- **I expected a Consul restart to wipe the registry.** Dev mode is in-memory and the services register only
  once, at startup, so I assumed routing would break until they were restarted. It did not: the Consul agent
  writes service definitions to `/consul/data/services` and restores them on start (visible in its debug log),
  so the services stay registered. The behaviour is now a test instead of a caveat. It would not hold with
  `docker compose down -v`, which deletes that data.
- **A killed container is only noticed by the health check.** `stop` deregisters cleanly, `kill` does not.
  The test shows the dead instance is dropped within 45 s. By configuration (10 s interval, 2 s timeout) the
  window should be about 12 s, during which the gateway can still pick the dead instance. I did not measure
  what clients see during that window, so I make no claim about it.

## Clean up

```bash
docker compose down
```

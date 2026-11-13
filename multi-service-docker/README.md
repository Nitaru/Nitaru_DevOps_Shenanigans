# Multi-Service Docker

A solution to the [roadmap.sh Multi-Service Docker project](https://roadmap.sh/projects/multiservice-docker):
a small notes app split into five containers, built with Docker best practices in mind.

```
                    ┌───────────────── frontend network ─────────────────┐
  browser ──:8080──▶│ proxy (nginx) ──/──────▶ web (React, served by nginx)│
                    │        └───────/api/──▶ api (Node.js / Express)      │
                    └─────────────────────────────┬──────────────────────┘
                                                  │
                    ┌──── backend network (internal, no outside access) ──┐
                    │              mongo (MongoDB)    redis (cache)       │
                    └──────────────────────────────────────────────────────┘
```

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `proxy` | `nginx:1.27-alpine` | Reverse proxy, the only container with a published port. `/api/*` goes to the API, everything else to the web app. |
| `web` | `msd/web` (custom) | React app (Vite). Multi-stage build: compiled on the custom Node base image, shipped on unprivileged nginx. |
| `api` | `msd/api` (custom) | Express API for notes. Reads go through Redis first; writes invalidate the cache. |
| `mongo` | `mongo:7` | Stores the notes. |
| `redis` | `redis:7-alpine` | Caches the notes list for 60s. |

## Docker features used

- **Docker Compose**: the whole stack is defined in [`docker-compose.yml`](docker-compose.yml).
- **Custom base image**: [`base/node-base`](base/node-base/Dockerfile) (Node 20 Alpine + `tini` + npm defaults) is the base for the API and for the web build stage.
- **Multi-stage build**: [`web/Dockerfile`](web/Dockerfile) builds with Node and ships only the static files on nginx. The final image is about 75MB instead of 200MB+.
- **Networks**: `frontend` for proxy/web/api, and `backend` marked `internal: true`, so MongoDB and Redis can't be reached from outside Docker.
- **Volumes**: `mongo-data` and `redis-data` (Redis runs with AOF persistence), so data survives `docker compose down`.
- **Secrets**: MongoDB and Redis passwords are Docker secrets mounted at `/run/secrets/*`. They're never put in environment variables or images. Mongo reads them via `*_FILE` variables, and the API reads them in [`api/src/config.js`](api/src/config.js).
- **Health checks**: every service has one, and `depends_on: condition: service_healthy` controls startup order (mongo/redis → api → web → proxy).
- **Optimized Dockerfiles**: dependency manifests are copied before the source code for layer caching, `npm ci --omit=dev` installs production deps only, `.dockerignore` files keep the build context small, and containers run as non-root users.
- **Logging and rotation**: a shared `x-logging` anchor sets the `json-file` driver with `max-size: 10m` and `max-file: 3` for every service. The API logs requests as JSON lines.

## Run it

Requires Docker with Compose, `make` and `openssl`.

```bash
make up
```

This:
1. generates random passwords in `secrets/` (git-ignored),
2. builds the custom base image `msd/node-base:1.0`,
3. builds and starts the stack.

Open <http://localhost:8080>.

## Try it

```bash
# First read hits MongoDB...
curl localhost:8080/api/notes          # {"source":"database", ...}
# ...the next one within 60s comes from Redis
curl localhost:8080/api/notes          # {"source":"cache", ...}

curl -X POST localhost:8080/api/notes -H 'Content-Type: application/json' -d '{"text":"hello"}'

docker compose ps                      # all services show (healthy)
docker compose logs -f api             # JSON request logs
```

## Other commands

```bash
make logs    # follow logs
make down    # stop (keeps data)
make clean   # stop and delete volumes
```

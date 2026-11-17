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

## Test it

```bash
scripts/test.sh          # 30 checks on its own project name and port (18081), about 80 seconds
KEEP=1 scripts/test.sh   # leave the stack running afterwards
```

The script builds everything, then checks the claims made above rather than only that the containers start:

| Area | What is checked |
|---|---|
| Health | all five services report healthy; the web app is served; the API reaches Mongo and Redis through the proxy |
| Caching | a read after a write comes from the database, the next one from Redis, and a write invalidates the cache again |
| API | invalid input (empty note, malformed id) is rejected, an unknown id returns 404, a delete returns 204 |
| Isolation | only the proxy publishes a port; Mongo is unreachable from the host; Mongo cannot reach the internet but can still reach Redis |
| Secrets | the passwords are in no container configuration, no log, and no image layer, are mounted as files, and the directory holding them is private (see below) |
| Users, logs | the API and web containers run as non-root; every service rotates logs at 10 MB, 3 files |
| Persistence | after a restart of the API the proxy finds it again, and a note survives `down` followed by `up` |

`PROXY_PORT` changes the published port (default 8080).

## Things I checked, and what I found

- **CI found a bug that never showed on my Mac: the stack did not start on Linux.** `generate-secrets.sh` made the
  password files `chmod 600`. Compose bind-mounts a secret file with the host file's owner and mode, and the
  containers read it as non-root users (Mongo as uid 999, the API as uid 1000), so on the GitHub runner Mongo
  failed with `/run/secrets/mongo_password: Permission denied`. Docker Desktop on macOS hides this, a Linux server
  does not, and a Linux server is what this README recommends. Compose has no `uid` or `mode` option for file
  secrets outside Swarm, so the fix is: files `644`, inside a directory that is `700`. Other users on the host
  cannot list the directory, while the containers reach the files through the bind mount. The test asserts both
  modes. The trade-off is real: anyone who can already read the directory (you, and root) can read the files,
  and so can any process running as you.

- **Every "is not present" check has a control.** A check that says "no secrets found" is only meaningful if the
  scan can find one, so the test first feeds it a known password and requires it to be detected. The network
  check likewise first proves that two containers on the backend network can reach each other, so a failed
  connection to the internet means isolation and not a broken probe.
- **I ran a sabotaged copy of the script** with two wrong expectations to confirm that failures are reported.
  It reported both.
- **The "75MB instead of 200MB+" claim holds, but depends on how it is measured.** `docker images` shows
  76 MB for the web image against 199 MB for its build base. `docker image inspect` shows 22 MB for the same
  image because it reports compressed size. The test uses the `docker images` figure and requires the web
  image to be under half the size of its base.
- **Only the custom images are checked for non-root.** The API and web containers run as non-root. In the
  official `mongo` image, `docker exec` reports uid 0, and I did not check whether `mongod` itself drops
  privileges, nor what the Redis and nginx processes run as, so I make no claim about them.
- **The proxy re-resolves the API after it restarts.** `nginx.conf` uses Docker's resolver with a 10-second
  cache and variables in `proxy_pass`, and the test restarts the API and requires the proxy to find it again.

## Other commands

```bash
make logs    # follow logs
make down    # stop (keeps data)
make clean   # stop and delete volumes
```

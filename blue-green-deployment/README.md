# Blue-Green Deployment

A solution to the [roadmap.sh Blue-Green Deployment project](https://roadmap.sh/projects/blue-green-deployment):
deploy a new version of an app next to the running one, check that it works, and only then
move traffic over, with no downtime and no data loss.

```
                          ┌──────────────┐
  users ──:8080──▶ router │    nginx     │ upstream app_active → app-blue OR app-green
                          └──────┬───────┘
                   live ┌────────┴────────┐ idle (previous version, kept for rollback)
                        ▼                 ▼
                  ┌──────────┐      ┌──────────┐
                  │ app-blue │      │app-green │      Prometheus :9090 scrapes both
                  │  v1.0.0  │      │  v2.0.0  │      Grafana    :3000 dashboard
                  └────┬─────┘      └────┬─────┘
                       └──── redis ──────┘   shared state → nothing lost on switch
```

## How a deployment works

[`scripts/deploy.sh <version>`](scripts/deploy.sh):

1. Reads the current state (which color is live) from `.deploy-state`.
2. Builds `bluegreen-app:<version>` and starts it in the **idle** color.
3. Waits for the container's Docker health check to report `healthy`.
4. Smoke tests the new container **directly** (`/version` must return the new version), before any user traffic reaches it.
5. Rewrites `nginx/upstream/active.conf`, validates it with `nginx -t`, and runs `nginx -s reload`. The reload is graceful: old workers finish their in-flight requests, so nothing is dropped.
6. Checks through the router that the new version is live and adds a deployment annotation in Grafana.

If step 3 or 4 fails, the script stops and the router is never touched. Users keep getting the old version.

The old color **keeps running**, so [`scripts/rollback.sh`](scripts/rollback.sh) switches back in about a second.
Both colors share Redis (the page's visit counter), so data survives switches.

## Run it

Requires Docker with Compose, `bash` and `curl`.

```bash
./scripts/deploy.sh v1.0.0     # first deploy goes to blue
open http://localhost:8080     # blue page, "Version v1.0.0"

./scripts/deploy.sh v2.0.0     # goes to green, traffic switches
./scripts/status.sh            # * marks the live color
./scripts/rollback.sh          # back to blue / v1.0.0
```

Prove there's no downtime by firing requests at the router during a deploy:

```bash
./scripts/zero-downtime-test.sh v3.0.0
# [..] Requests during deploy: 148, failed: 0
```

Clean up:

```bash
docker compose --env-file .deploy-state down -v && rm .deploy-state nginx/upstream/active.conf
```

## Monitoring (bonus)

- The app exposes Prometheus metrics at `/metrics`: `app_requests_total{color,version}` and `app_info{color,version}`.
- **Prometheus** (<http://localhost:9090>) scrapes both slots every 5s.
- **Grafana** (<http://localhost:3000>, `admin` / `admin`) has a provisioned **Blue-Green Deployment** dashboard. It shows the version in each slot, whether each slot is up, live traffic per color (you can watch it move from one color to the other), and an annotation for every deploy and rollback.

## CI/CD (bonus)

[`.github/workflows/blue-green-deployment.yml`](../.github/workflows/blue-green-deployment.yml) runs on every push to `main` that touches this folder:

1. **test**: on the GitHub runner, it deploys a baseline version, then deploys the pushed commit while firing requests at the router (fails if any request errors), then tests rollback.
2. **deploy**: copies the project to your server over SSH and runs `./scripts/deploy.sh <commit-sha>`. It is skipped until a server is configured. To enable it, add these in *Settings → Secrets and variables → Actions*:

   | Type | Name | Value |
   |------|------|-------|
   | Variable | `DEPLOY_HOST` | server IP / hostname |
   | Variable | `DEPLOY_USER` | SSH user (with Docker access) |
   | Secret | `DEPLOY_SSH_KEY` | private key for that user |

# DevOps Hands On

Hands-on DevOps projects from the [roadmap.sh DevOps project list](https://roadmap.sh/devops/projects).
Each folder is a self-contained project with its own README, and each one runs locally with Docker Compose.

| Project | What it covers | Stack |
|---------|----------------|-------|
| [Service Discovery](service-discovery) | Services register themselves with Consul; an API gateway discovers healthy instances and load-balances across them | Consul, Python/Flask, Docker Compose |
| [Multi-Service Docker](multi-service-docker) | A 5-service app built with Docker best practices: custom base image, multi-stage builds, isolated networks, volumes, secrets, health checks, log rotation | React, Node.js/Express, MongoDB, Redis, Nginx |
| [Blue-Green Deployment](blue-green-deployment) | Zero-downtime releases: deploy to the idle color, health check and smoke test, switch nginx traffic, instant rollback. Includes a CI/CD pipeline and monitoring | Bash, Nginx, Docker, GitHub Actions, Prometheus, Grafana |
| [Monitoring with Prometheus & Grafana](monitoring-prometheus-grafana) | Full observability stack: system, nginx, Redis and custom exporters, Docker service discovery, recording and alerting rules, provisioned dashboards, Grafana alerting, Loki logs | Prometheus, Grafana, Loki, Promtail, Node.js |

## Repository layout

```
.
├── service-discovery/             # Consul + 3 dummy services + API gateway
├── multi-service-docker/          # React + Express + MongoDB + Redis + Nginx
├── blue-green-deployment/         # deploy / rollback scripts, router, monitoring
├── monitoring-prometheus-grafana/ # Prometheus, Grafana, Loki, exporters
└── .github/workflows/             # CI/CD for the blue-green project
```

## Running a project

Requirements: Docker with Compose v2. Some projects also need `make`, `bash`, `curl` and `openssl`.

```bash
git clone https://github.com/Nitaru/Devops-Hands-On.git
cd Devops-Hands-On/<project-folder>
# then follow that project's README
```

Several projects publish port `8080` (and some `3000`/`9090`), so run one at a time or stop the previous one with `docker compose down`.

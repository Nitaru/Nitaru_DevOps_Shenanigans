import itertools
import os

import requests
from flask import Flask, Response, jsonify, request

CONSUL_URL = os.environ.get("CONSUL_URL", "http://consul:8500")
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "8080"))

app = Flask(__name__)
# Per-service round-robin counters so multiple instances share load.
_counters = {}


def discover(service_name):
    """Return healthy instances of a service from Consul's health API."""
    r = requests.get(
        f"{CONSUL_URL}/v1/health/service/{service_name}",
        params={"passing": "true"},
        timeout=3,
    )
    r.raise_for_status()
    return [(e["Service"]["Address"], e["Service"]["Port"]) for e in r.json()]


def pick(service_name, instances):
    counter = _counters.setdefault(service_name, itertools.count())
    return instances[next(counter) % len(instances)]


@app.get("/")
def index():
    return jsonify(
        message="API Gateway",
        usage="GET /<service-name>/<path>, e.g. /service-a/info",
        services="GET /services",
    )


@app.get("/services")
def services():
    """List every service registered in Consul with its healthy instances."""
    catalog = requests.get(f"{CONSUL_URL}/v1/catalog/services", timeout=3).json()
    return jsonify(
        {
            name: [f"{a}:{p}" for a, p in discover(name)]
            for name in catalog
            if name != "consul"
        }
    )


@app.route("/<service_name>/", defaults={"path": ""}, methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
@app.route("/<service_name>/<path:path>", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
def proxy(service_name, path):
    try:
        instances = discover(service_name)
    except requests.RequestException as e:
        return jsonify(error=f"Consul unavailable: {e}"), 503
    if not instances:
        return jsonify(error=f"No healthy instances of '{service_name}'"), 404

    address, port = pick(service_name, instances)
    try:
        upstream = requests.request(
            request.method,
            f"http://{address}:{port}/{path}",
            params=request.args,
            data=request.get_data(),
            headers={k: v for k, v in request.headers if k.lower() != "host"},
            timeout=5,
        )
    except requests.RequestException as e:
        return jsonify(error=f"Upstream {service_name} failed: {e}"), 502

    headers = {k: v for k, v in upstream.headers.items()
               if k.lower() not in ("content-encoding", "content-length", "transfer-encoding", "connection")}
    headers["X-Served-By"] = f"{address}:{port}"
    return Response(upstream.content, upstream.status_code, headers)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=GATEWAY_PORT)

import os
import socket

import redis
from flask import Flask, jsonify, render_template
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

VERSION = os.environ.get("APP_VERSION", "dev")
COLOR = os.environ.get("APP_COLOR", "unknown")

app = Flask(__name__)
# Redis is shared by blue and green, so state survives a switch.
store = redis.Redis(host=os.environ.get("REDIS_HOST", "redis"), port=6379, decode_responses=True)

REQUESTS = Counter("app_requests_total", "HTTP requests served", ["color", "version", "path"])
INFO = Gauge("app_info", "Version running in this container", ["color", "version"])
INFO.labels(COLOR, VERSION).set(1)


@app.get("/")
def index():
    REQUESTS.labels(COLOR, VERSION, "/").inc()
    visits = store.incr("visits")
    return render_template("index.html", version=VERSION, color=COLOR, visits=visits, host=socket.gethostname())


@app.get("/version")
def version():
    REQUESTS.labels(COLOR, VERSION, "/version").inc()
    return jsonify(version=VERSION, color=COLOR)


@app.get("/health")
def health():
    try:
        store.ping()
    except redis.RedisError as e:
        return jsonify(status="error", error=str(e)), 503
    return jsonify(status="ok", version=VERSION)


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

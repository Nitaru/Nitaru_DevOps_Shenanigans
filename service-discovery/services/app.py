import atexit
import os
import signal
import socket
import sys
import time
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify

SERVICE_NAME = os.environ.get("SERVICE_NAME", "service-a")
SERVICE_DISPLAY_NAME = os.environ.get("SERVICE_DISPLAY_NAME", "Service A")
SERVICE_PORT = int(os.environ.get("SERVICE_PORT", "5000"))
SERVICE_ADDRESS = os.environ.get("SERVICE_ADDRESS", socket.gethostname())
CONSUL_URL = os.environ.get("CONSUL_URL", "http://consul:8500")
SERVICE_ID = f"{SERVICE_NAME}-{socket.gethostname()}"

app = Flask(__name__)


@app.get("/info")
def info():
    return jsonify(
        service=SERVICE_DISPLAY_NAME,
        id=SERVICE_ID,
        timestamp=datetime.now(timezone.utc).isoformat(),
    )


@app.get("/health")
def health():
    return jsonify(status="ok")


def register():
    payload = {
        "ID": SERVICE_ID,
        "Name": SERVICE_NAME,
        "Address": SERVICE_ADDRESS,
        "Port": SERVICE_PORT,
        "Tags": ["dummy", "flask"],
        "Check": {
            "HTTP": f"http://{SERVICE_ADDRESS}:{SERVICE_PORT}/health",
            "Interval": "10s",
            "Timeout": "2s",
            "DeregisterCriticalServiceAfter": "1m",
        },
    }
    # Consul may still be starting up, so retry for a while.
    for attempt in range(1, 31):
        try:
            r = requests.put(f"{CONSUL_URL}/v1/agent/service/register", json=payload, timeout=3)
            r.raise_for_status()
            print(f"[{SERVICE_NAME}] registered with Consul as {SERVICE_ID}", flush=True)
            return
        except requests.RequestException as e:
            print(f"[{SERVICE_NAME}] registration attempt {attempt} failed: {e}", flush=True)
            time.sleep(2)
    sys.exit(f"[{SERVICE_NAME}] could not register with Consul")


def deregister(*_):
    try:
        requests.put(f"{CONSUL_URL}/v1/agent/service/deregister/{SERVICE_ID}", timeout=3)
        print(f"[{SERVICE_NAME}] deregistered from Consul", flush=True)
    except requests.RequestException:
        pass


if __name__ == "__main__":
    register()
    atexit.register(deregister)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    app.run(host="0.0.0.0", port=SERVICE_PORT)

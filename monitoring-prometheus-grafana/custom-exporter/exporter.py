"""
Custom Prometheus exporter for the shop's business data.

The app only knows about requests it handles. This exporter reads the shop's
Redis data on every scrape and exposes business-level numbers (revenue,
backlog, orders per product) that no off-the-shelf exporter can provide.
"""
import os
import time

import redis
from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily


class ShopCollector:
    def __init__(self, client):
        self.redis = client

    def collect(self):
        up = GaugeMetricFamily("shop_exporter_redis_up", "Whether the exporter could read Redis")
        start = time.time()
        try:
            pending = self.redis.llen("orders:pending")
            fulfilled = int(self.redis.get("orders:fulfilled") or 0)
            revenue = float(self.redis.get("orders:revenue") or 0)
            by_product = self.redis.hgetall("orders:by_product")
        except redis.RedisError:
            up.add_metric([], 0)
            yield up
            return
        up.add_metric([], 1)
        yield up

        yield GaugeMetricFamily("shop_orders_pending", "Orders waiting to be fulfilled", value=pending)
        yield CounterMetricFamily("shop_orders_fulfilled", "Orders fulfilled", value=fulfilled)
        yield CounterMetricFamily("shop_revenue_dollars", "Total revenue", value=revenue)

        per_product = GaugeMetricFamily(
            "shop_orders_by_product", "Orders placed per product (all time)", labels=["product"]
        )
        for product, count in by_product.items():
            per_product.add_metric([product], int(count))
        yield per_product

        yield GaugeMetricFamily(
            "shop_exporter_scrape_duration_seconds", "Time spent reading Redis", value=time.time() - start
        )


if __name__ == "__main__":
    client = redis.Redis(host=os.environ.get("REDIS_HOST", "redis"), decode_responses=True)
    REGISTRY.register(ShopCollector(client))
    port = int(os.environ.get("PORT", "9200"))
    start_http_server(port)
    print(f"shop exporter listening on :{port}", flush=True)
    while True:
        time.sleep(3600)

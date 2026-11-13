#!/bin/sh
# Generates steady fake traffic so the dashboards have something to show.
TARGET="${TARGET:-http://nginx}"
PRODUCTS="keyboard mouse monitor headset"

while true; do
  curl -s -o /dev/null "$TARGET/api/products"
  product=$(echo $PRODUCTS | tr ' ' '\n' | shuf -n 1)
  curl -s -o /dev/null -X POST "$TARGET/api/orders" \
    -H 'Content-Type: application/json' \
    -d "{\"product\":\"$product\",\"quantity\":$(shuf -i 1-3 -n 1)}"
  # Every now and then hit a route that doesn't exist, to produce some 404s
  [ "$(shuf -i 1-20 -n 1)" = 1 ] && curl -s -o /dev/null "$TARGET/api/missing"
  sleep "0.$(shuf -i 1-5 -n 1)"
done

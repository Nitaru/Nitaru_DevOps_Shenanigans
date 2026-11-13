const express = require("express");
const { createClient } = require("redis");
const metrics = require("./metrics");

const PORT = Number(process.env.PORT || 3000);
const PRODUCTS = { keyboard: 49, mouse: 19, monitor: 199, headset: 79 };

const redis = createClient({ url: process.env.REDIS_URL || "redis://redis:6379" });
redis.on("error", (err) => log("error", "redis error", { error: err.message }));

const app = express();
app.use(express.json());
app.use(metrics.middleware);

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...extra }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.get("/health", (req, res) => res.json({ status: "ok" }));

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", metrics.register.contentType);
  res.send(await metrics.register.metrics());
});

app.get("/api/products", async (req, res) => {
  await sleep(Math.random() * 50);
  res.json(PRODUCTS);
});

app.post("/api/orders", async (req, res) => {
  const product = req.body.product;
  if (!PRODUCTS[product]) {
    return res.status(400).json({ error: "unknown product" });
  }
  // Simulate some work and an occasional slow or failing payment provider
  await sleep(Math.random() < 0.05 ? 400 + Math.random() * 600 : Math.random() * 80);
  if (Math.random() < 0.03) {
    metrics.paymentFailures.inc();
    log("warn", "payment failed", { product });
    return res.status(502).json({ error: "payment failed" });
  }

  const quantity = Math.max(1, Number(req.body.quantity) || 1);
  const total = PRODUCTS[product] * quantity;
  const id = await redis.incr("orders:next_id");
  await redis.multi()
    .hIncrBy("orders:by_product", product, 1)
    .incrByFloat("orders:revenue", total)
    .lPush("orders:pending", String(id))
    .exec();

  metrics.ordersCreated.inc({ product });
  metrics.orderValue.observe(total);
  log("info", "order created", { id, product, quantity, total });
  res.status(201).json({ id, product, quantity, total });
});

// Background "worker" that fulfils pending orders at a limited pace
async function fulfilOrders() {
  try {
    const id = await redis.rPop("orders:pending");
    if (id) await redis.incr("orders:fulfilled");
  } catch (err) {
    log("error", "fulfilment failed", { error: err.message });
  }
}

app.use((err, req, res, next) => {
  log("error", "unhandled error", { error: err.message });
  res.status(500).json({ error: "internal server error" });
});

redis.connect().then(() => {
  setInterval(fulfilOrders, 300);
  app.listen(PORT, () => log("info", "shop-api listening", { port: PORT }));
});

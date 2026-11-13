const client = require("prom-client");

const register = new client.Registry();
register.setDefaultLabels({ app: "shop-api" });
// CPU, memory, event loop lag, GC... for the Node.js process itself
client.collectDefaultMetrics({ register });

const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request latency",
  labelNames: ["method", "route", "status"],
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [register],
});

const ordersCreated = new client.Counter({
  name: "shop_orders_created_total",
  help: "Orders placed",
  labelNames: ["product"],
  registers: [register],
});

const orderValue = new client.Histogram({
  name: "shop_order_value_dollars",
  help: "Value of placed orders",
  buckets: [5, 10, 25, 50, 100, 250],
  registers: [register],
});

const paymentFailures = new client.Counter({
  name: "shop_payment_failures_total",
  help: "Orders rejected because the (simulated) payment failed",
  registers: [register],
});

function middleware(req, res, next) {
  const end = httpDuration.startTimer({ method: req.method });
  res.on("finish", () => {
    // Use the route pattern, not the raw URL, to keep label cardinality low
    const route = req.route ? req.baseUrl + req.route.path : "unmatched";
    end({ route, status: res.statusCode });
  });
  next();
}

module.exports = { register, middleware, ordersCreated, orderValue, paymentFailures };

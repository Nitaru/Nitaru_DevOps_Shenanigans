const express = require("express");
const { MongoClient, ObjectId } = require("mongodb");
const { createClient } = require("redis");
const config = require("./config");

const CACHE_KEY = "notes:all";

const app = express();
app.use(express.json());

const mongo = new MongoClient(config.mongoUrl);
const redis = createClient({ url: config.redisUrl });
redis.on("error", (err) => console.error("redis error:", err.message));

let notes;

function log(msg, extra = {}) {
  console.log(JSON.stringify({ time: new Date().toISOString(), msg, ...extra }));
}

app.use((req, res, next) => {
  const start = Date.now();
  res.on("finish", () =>
    log("request", { method: req.method, path: req.path, status: res.statusCode, ms: Date.now() - start })
  );
  next();
});

app.get("/api/health", async (req, res) => {
  try {
    await mongo.db("admin").command({ ping: 1 });
    await redis.ping();
    res.json({ status: "ok" });
  } catch (err) {
    res.status(503).json({ status: "error", error: err.message });
  }
});

app.get("/api/notes", async (req, res, next) => {
  try {
    const cached = await redis.get(CACHE_KEY);
    if (cached) {
      return res.json({ source: "cache", notes: JSON.parse(cached) });
    }
    const docs = await notes.find().sort({ createdAt: -1 }).limit(100).toArray();
    await redis.set(CACHE_KEY, JSON.stringify(docs), { EX: config.cacheTtl });
    res.json({ source: "database", notes: docs });
  } catch (err) {
    next(err);
  }
});

app.post("/api/notes", async (req, res, next) => {
  const text = (req.body.text || "").trim();
  if (!text) {
    return res.status(400).json({ error: "text is required" });
  }
  try {
    const doc = { text, createdAt: new Date() };
    const { insertedId } = await notes.insertOne(doc);
    await redis.del(CACHE_KEY);
    res.status(201).json({ _id: insertedId, ...doc });
  } catch (err) {
    next(err);
  }
});

app.delete("/api/notes/:id", async (req, res, next) => {
  if (!ObjectId.isValid(req.params.id)) {
    return res.status(400).json({ error: "invalid id" });
  }
  try {
    const { deletedCount } = await notes.deleteOne({ _id: new ObjectId(req.params.id) });
    await redis.del(CACHE_KEY);
    res.status(deletedCount ? 204 : 404).end();
  } catch (err) {
    next(err);
  }
});

app.use((err, req, res, next) => {
  log("error", { error: err.message });
  res.status(500).json({ error: "internal server error" });
});

async function main() {
  await mongo.connect();
  await redis.connect();
  notes = mongo.db(config.mongoDb).collection("notes");
  const server = app.listen(config.port, () => log("api listening", { port: config.port }));

  const shutdown = async () => {
    log("shutting down");
    server.close();
    await Promise.allSettled([mongo.close(), redis.quit()]);
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  log("startup failed", { error: err.message });
  process.exit(1);
});

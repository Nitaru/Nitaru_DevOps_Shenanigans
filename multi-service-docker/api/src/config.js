const fs = require("fs");

// Read a value from a Docker secret file, falling back to an env var for local dev.
function secret(name, envFallback) {
  const file = process.env[`${name}_FILE`];
  if (file && fs.existsSync(file)) {
    return fs.readFileSync(file, "utf8").trim();
  }
  return process.env[envFallback || name];
}

const mongoUser = process.env.MONGO_USER || "root";
const mongoPassword = secret("MONGO_PASSWORD");
const mongoHost = process.env.MONGO_HOST || "mongo";

module.exports = {
  port: Number(process.env.PORT || 3000),
  mongoUrl: `mongodb://${mongoUser}:${encodeURIComponent(mongoPassword)}@${mongoHost}:27017/?authSource=admin`,
  mongoDb: process.env.MONGO_DB || "notes",
  redisUrl: `redis://:${encodeURIComponent(secret("REDIS_PASSWORD"))}@${process.env.REDIS_HOST || "redis"}:6379`,
  cacheTtl: Number(process.env.CACHE_TTL_SECONDS || 60),
};

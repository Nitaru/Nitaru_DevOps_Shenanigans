# Shared base image for the web build stage and the API service.
FROM node:20-alpine

# tini reaps zombie processes and forwards signals to node properly
RUN apk add --no-cache tini wget \
    && npm config set update-notifier false \
    && npm config set fund false \
    && npm config set audit false

ENV NODE_ENV=production
WORKDIR /app

ENTRYPOINT ["/sbin/tini", "--"]

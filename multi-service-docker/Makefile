BASE_IMAGE := msd/node-base:1.0

.PHONY: up down base secrets logs ps clean

up: secrets base
	docker compose up --build -d

base:
	docker build -t $(BASE_IMAGE) base/node-base

secrets:
	./scripts/generate-secrets.sh

down:
	docker compose down

logs:
	docker compose logs -f

ps:
	docker compose ps

# Removes containers AND the database/cache volumes
clean:
	docker compose down -v

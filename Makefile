.PHONY: help build up down restart logs status clean backup restore test scale health

# Default target
help:
	@echo "Semantic Fabric - Available Commands"
	@echo "===================================="
	@echo ""
	@echo "Setup & Deployment:"
	@echo "  make deploy       - Initial deployment (build + up + health check)"
	@echo "  make build        - Build Docker images"
	@echo "  make up           - Start all services"
	@echo "  make down         - Stop and remove all services"
	@echo "  make restart      - Restart all services"
	@echo ""
	@echo "Monitoring:"
	@echo "  make logs         - Follow all logs"
	@echo "  make status       - Show service status"
	@echo "  make health       - Check cluster health"
	@echo "  make stats        - Show cluster statistics"
	@echo ""
	@echo "Scaling:"
	@echo "  make scale N=5    - Scale workers to N instances"
	@echo "  make add-worker   - Add one worker node"
	@echo ""
	@echo "Maintenance:"
	@echo "  make backup       - Create manual backup"
	@echo "  make restore      - Restore from latest backup"
	@echo "  make clean        - Remove all data (WARNING: destructive)"
	@echo "  make vacuum       - Optimize databases"
	@echo ""
	@echo "Development:"
	@echo "  make test         - Run test suite"
	@echo "  make shell        - Open shell in coordinator"
	@echo "  make iex          - Open IEx console in coordinator"
	@echo ""

# Deployment commands
deploy:
	@chmod +x deploy.sh
	@./deploy.sh

build:
	@echo "Building Docker images..."
	@docker compose build

up:
	@echo "Starting services..."
	@docker compose up -d
	@sleep 5
	@make health

down:
	@echo "Stopping services..."
	@docker compose down

restart:
	@echo "Restarting services..."
	@docker compose restart
	@sleep 5
	@make health

# Monitoring commands
logs:
	@docker compose logs -f

status:
	@docker compose ps

health:
	@echo "Checking cluster health..."
	@curl -s http://localhost/health || echo "API not responding"
	@echo ""
	@echo "Service Status:"
	@docker compose ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"

stats:
	@echo "Cluster Statistics:"
	@curl -s http://localhost/api/stats | jq '.' || echo "Stats endpoint not available"

# Scaling commands
scale:
ifndef N
	@echo "Usage: make scale N=<number_of_workers>"
	@exit 1
endif
	@echo "Scaling workers to $(N) instances..."
	@docker compose up -d --scale worker=$(N)

add-worker:
	@echo "Adding one worker node..."
	@CURRENT=$$(docker compose ps worker | grep -c worker); \
	NEW=$$((CURRENT + 1)); \
	docker compose up -d --scale worker=$$NEW

# Maintenance commands
backup:
	@echo "Creating manual backup..."
	@docker compose exec backup /backup/backup.sh

restore:
	@echo "Restoring from latest backup..."
	@./restore.sh

vacuum:
	@echo "Optimizing databases..."
	@docker compose exec coordinator sqlite3 /data/routing/index.db "VACUUM; ANALYZE;"
	@echo "Database optimization complete"

clean:
	@echo "WARNING: This will remove all data!"
	@read -p "Are you sure? (yes/no): " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		echo "Stopping services..."; \
		docker compose down -v; \
		echo "Removing data directories..."; \
		rm -rf data/*; \
		echo "Clean complete"; \
	else \
		echo "Aborted"; \
	fi

# Development commands
test:
	@echo "Running test suite..."
	@docker compose exec coordinator mix test

shell:
	@docker compose exec coordinator /bin/bash

iex:
	@docker compose exec coordinator bin/semantic_fabric remote

# Local Development Commands (using asdf)
.PHONY: local-deps local-compile local-test local-run local-format local-iex
local-deps:
	@echo "Fetching local dependencies..."
	@mix deps.get

local-compile:
	@echo "Compiling local project..."
	@mix compile

local-test:
	@echo "Running local test suite..."
	@mix test

local-run:
	@echo "Running local application..."
	@mix run --no-halt

local-format:
	@echo "Formatting local code..."
	@mix format

local-iex:
	@echo "Starting local IEx console..."
	@iex -S mix

# Utility commands
.PHONY: update-deps
update-deps:
	@echo "Updating dependencies..."
	@docker compose exec coordinator mix deps.update --all
	@docker compose exec coordinator mix deps.compile

.PHONY: format
format:
	@echo "Formatting code..."
	@docker compose exec coordinator mix format

.PHONY: lint
lint:
	@echo "Running linter..."
	@docker compose exec coordinator mix credo

.PHONY: dialyzer
dialyzer:
	@echo "Running dialyzer..."
	@docker compose exec coordinator mix dialyzer

# Advanced operations
.PHONY: rebuild-index
rebuild-index:
	@echo "Rebuilding routing index..."
	@docker compose exec coordinator mix semantic_fabric.rebuild_index

.PHONY: recompute-pagerank
recompute-pagerank:
	@echo "Recomputing PageRank..."
	@docker compose exec coordinator mix semantic_fabric.recompute_pagerank

.PHONY: migrate-shards
migrate-shards:
	@echo "Migrating shards..."
	@docker compose exec coordinator mix semantic_fabric.migrate_shards

.PHONY: export-metrics
export-metrics:
	@echo "Exporting metrics..."
	@curl -s http://localhost:9090/api/v1/query?query=up > metrics_export.json
	@echo "Metrics exported to metrics_export.json"

.PHONY: benchmark
benchmark:
	@echo "Running benchmark..."
	@./benchmark.sh

# Docker management
.PHONY: prune
prune:
	@echo "Pruning unused Docker resources..."
	@docker system prune -f
	@docker volume prune -f

.PHONY: images
images:
	@docker images | grep semantic-fabric

.PHONY: volumes
volumes:
	@docker volume ls | grep semantic-fabric

# Network troubleshooting
.PHONY: network-inspect
network-inspect:
	@docker network inspect semantic-fabric_semantic-fabric

.PHONY: ping-test
ping-test:
	@echo "Testing connectivity..."
	@docker compose exec coordinator ping -c 3 worker-1
	@docker compose exec coordinator ping -c 3 worker-2
	@docker compose exec coordinator ping -c 3 redis

# Configuration
.PHONY: config-validate
config-validate:
	@echo "Validating configuration..."
	@docker compose config

.PHONY: env-check
env-check:
	@echo "Checking environment configuration..."
	@test -f .env || (echo "ERROR: .env file not found" && exit 1)
	@echo "✓ .env file exists"
	@grep -q OPENAI_API_KEY .env && echo "✓ OPENAI_API_KEY configured" || echo "⚠ OPENAI_API_KEY not set"
	@grep -q CLUSTER_SECRET .env && echo "✓ CLUSTER_SECRET configured" || echo "⚠ CLUSTER_SECRET not set"

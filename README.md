# MosaicDB

Distributed semantic search built on SQLite shards ( a sketch )

## Setup

```bash
make build
make up
```

Done. Go to http://localhost/health

## What It Does

Takes queries, searches across SQLite database shards, returns ranked results.

Each shard = immutable SQLite file with documents, vectors, and PageRank scores.

This is a system for performing semantic search across many distributed chunks of data (shards) using embedding-based vector search (via sqlite-vss) and then ranking the results.

All in a federated/distributed way, inspired by scalable distributed systems like Riak.

## Services

- **Coordinator** (4040): Routes queries
- **Nginx** (80): Load balancer
- **Redis** (6379): Cache
- **Prometheus** (9090): Metrics
- **Grafana** (3000): Dashboards

## API

```bash
# Health
curl http://localhost/health

# Search (placeholder)
curl -X POST http://localhost/api/search \
  -d '{"query":"test"}' \
  -H "Content-Type: application/json"
```

## Commands

```bash
make up       # Start
make down     # Stop  
make logs     # Logs
make restart  # Restart
```

## Local Dev

```bash
mix deps.get
mix run --no-halt
```

## Architecture

```
Query → Nginx → Coordinator → Shards (SQLite files)
                    ↓
                  Cache (Redis)
```

## Scaling

Edit `docker-compose.yml`, add more workers, restart.

## Docs

- `docs/ARCHITECTURE.md` - How it works
- `docs/DEPLOYMENT_GUIDE.md` - Production setup

## License

MIT

# MosaicDB

### A Distributed, Federated Semantic Search Engine Built on SQLite Shards

MosaicDB is an experimental distributed query engine performing **hybrid vector + metadata search** across many **immutable SQLite shard files**. Each shard contains:

* Document text or metadata
* Vector embeddings (`sqlite-vss`)
* PageRank or other ranking signals

Elixir acts as the **coordinator and control plane**, orchestrating fan-out queries, retries, merges, caching, and ranking.

---

# Features

* Federated search across multiple SQLite shards
* Vector similarity search using `sqlite-vss`
* Metadata-aware filtering
* PageRank-based reranking
* LRU embedding cache
* Distributed coordinator architecture
* HTTP API for search
* Metrics via Prometheus/Grafana

MosaicDB combines **SQLite simplicity with Erlang/Elixir scale**. Each node is a lightweight SQLite database capable of storing both vector embeddings and structured metadata. Distributed across multiple nodes, MosaicDB provides fault-tolerant, scalable storage **without the overhead of managed clusters**.

---

# Feature Comparison

| Feature         | PostgreSQL                    | Pinecone      | Weaviate      | MosaicDB (SQLite nodes)           |
| --------------- | ----------------------------- | ------------- | ------------- | --------------------------------- |
| SQL support     | Yes                           | No            | No            | Yes, native SQLite queries        |
| Vector search   | Extensions needed (pgvector)  | Yes           | Yes           | Yes, exact or approximate         |
| Distribution    | Manual (sharding/replication) | Managed       | Managed       | Built-in via Elixir/Erlang        |
| Fault tolerance | Manual / HA setups            | Cloud-managed | Cloud-managed | Erlang/Elixir supervision trees   |
| Lightweight     | Moderate                      | No            | No            | Each node is a single SQLite file |
| Edge-ready      | No                            | No            | No            | Yes, nodes are self-contained     |

**Developer Pitch:**
MosaicDB gives developers a **lightweight, distributed vector + relational database** where each node is just a SQLite file. Fully SQL-capable, fault-tolerant via Erlang/Elixir, and easy to deploy at the edge — you get vector search + relational queries in one place, without complex cluster management or cloud lock-in. It’s **SQLite simplicity with Erlang reliability**.

---

# Why Elixir?

MosaicDB uses Elixir for its coordination layer because it naturally fits **federated query execution**:

### Concurrency for fan-out search

Each shard query runs as an isolated BEAM process—no thread pools, no shared state, no locks.

### Supervisor-based fault tolerance

Shard errors, timeouts, or node failures are isolated and automatically recovered.

### Predictable under load

The BEAM scheduler ensures slow shards do not block others.

### Built-in distribution

Elixir nodes auto-discover and form a cluster, enabling multi-node coordination without external registries.

### Clean pipeline composition

Query planning, merging, and reranking are expressed using functional pipelines and pattern matching.

### Observability

LiveDashboard, telemetry, and introspection tools simplify distributed debugging.

**In short:** Elixir is the resilient, concurrent **control plane** around fast SQLite shards.

---

# Quick Start

## Build and run

```bash
make build
make up
```

Check health:

```bash
curl http://localhost/health
```

---

# API

### Health

```bash
curl http://localhost/health
```

### Search (placeholder API)

```bash
curl -X POST http://localhost/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "test"}'
```

---

# Components

| Service     | Port | Description                |
| ----------- | ---- | -------------------------- |
| Coordinator | 4040 | Elixir-based query router  |
| Nginx       | 80   | Load balancer / entrypoint |
| Redis       | 6379 | Metadata + embedding cache |
| Prometheus  | 9090 | Metrics                    |
| Grafana     | 3000 | Dashboards                 |

---

# Development

Install dependencies:

```bash
mix deps.get
```

Run the system:

```bash
mix run --no-halt
```

---

# Basic Architecture

```
Client Query
      │
    Nginx
      │
  Coordinator (Elixir)
 ┌────┴─────────────┐
 │ fan-out async RPC│
 └────┬─────────────┘
  Many SQLite Shards
      │
  Vector + metadata search
      │
  Coordinator merges + ranks
      │
    Response
```

---

# Scaling

To scale horizontally, edit `docker-compose.yml` and increase coordinator workers:

```yaml
scale: 4
```

Then:

```bash
make restart
```

Elixir nodes will auto-discover each other (via libcluster) and share load.

---

# Documentation

* `docs/ARCHITECTURE.md` — data flow, shard layout, search pipeline
* `docs/DEPLOYMENT_GUIDE.md` — running MosaicDB in production
* `docs/SHARD_FORMAT.md` — SQLite schema, embeddings, PageRank structure

---

# License

MIT

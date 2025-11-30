# MosaicDB

### A Distributed, Federated Semantic Search Engine Built on SQLite Shards

MosaicDB is an experimental distributed query engine performing **hybrid vector + metadata search** across many **immutable SQLite shard files**. Each shard contains:

* Document text or metadata
* Vector embeddings (`sqlite-vec`)
* PageRank or other ranking signals

Elixir acts as the **coordinator and control plane**, orchestrating fan-out queries, retries, merges, caching, and ranking.

---

## Features

* Federated search across multiple SQLite shards
* Vector similarity search using `sqlite-vec`
* Metadata-aware filtering
* PageRank-based reranking
* LRU embedding cache
* Distributed coordinator architecture
* HTTP API for search
* Metrics via Prometheus/Grafana
* GPU-accelerated embeddings (optional)

MosaicDB combines **SQLite simplicity with Erlang/Elixir scale**. Each node is a lightweight SQLite database capable of storing both vector embeddings and structured metadata. Distributed across multiple nodes, MosaicDB provides fault-tolerant, scalable storage **without the overhead of managed clusters**.

---

## Feature Comparison

| Feature         | PostgreSQL                    | Pinecone      | Weaviate      | MosaicDB (SQLite nodes)           |
| --------------- | ----------------------------- | ------------- | ------------- | --------------------------------- |
| SQL support     | Yes                           | No            | No            | Yes, native SQLite queries        |
| Vector search   | Extensions needed (pgvector)  | Yes           | Yes           | Yes, exact or approximate         |
| Distribution    | Manual (sharding/replication) | Managed       | Managed       | Built-in via Elixir/Erlang        |
| Fault tolerance | Manual / HA setups            | Cloud-managed | Cloud-managed | Erlang/Elixir supervision trees   |
| Lightweight     | Moderate                      | No            | No            | Each node is a single SQLite file |
| Edge-ready      | No                            | No            | No            | Yes, nodes are self-contained     |

**Developer Pitch:**

MosaicDB gives developers a **lightweight, distributed vector + relational database** where each node is just a SQLite file. Fully SQL-capable, fault-tolerant via Erlang/Elixir, and easy to deploy at the edge — you get vector search + relational queries in one place, without complex cluster management or cloud lock-in. It's **SQLite simplicity with Erlang reliability**.

---

## Why Elixir?

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

## Performance Highlights

### CPU Performance
- **Batch ingestion**: ~157ms per document
- **Cold queries**: ~700-750ms (embedding + search)
- **Hot queries**: ~8-16ms (cached embeddings, 44-81x faster)
- **Throughput**: 10 parallel queries in 23ms

### GPU Performance (CUDA)
- **Batch ingestion**: ~57ms per document (2.7x faster)
- **Cold queries**: ~150-160ms (4-5x faster)
- **Hot queries**: ~13-16ms (cached embeddings, 8-10x faster)
- **Throughput**: 10 parallel queries in 17ms

---

## Quick Start

### CPU Version
```bash
docker compose up --build
```

### GPU Version (CUDA)
```bash
docker compose -f docker-compose.cuda.yml up -d --build
```

### Check Health
```bash
curl http://localhost/health
```

---

## API

### Health Check
```bash
curl http://localhost/health
```

### Search
```bash
curl -X POST http://localhost/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "test"}'
```

---

## Load Testing

### CPU Load Test
```bash
docker compose up --build
docker compose --profile load-test run --rm k6 run k6_tests/load_test.js
```

### CUDA Load Test
```bash
docker compose -f docker-compose.cuda.yml up -d
docker compose -f docker-compose.cuda.yml --profile load-test run --rm k6 run k6_tests/load_test.js
```

---

## Development

Install dependencies:
```bash
mix deps.get
```

Run the system:
```bash
mix run --no-halt
```

---

## Documentation

* `docs/ARCHITECTURE.md` — data flow, shard layout, search pipeline
* `docs/DEPLOYMENT_GUIDE.md` — running MosaicDB in production
* `docs/SHARD_FORMAT.md` — SQLite schema, embeddings, PageRank structure

---

## License

MIT


# mosaic_demo.sh

```
CPU: 13th Gen Intel(R) Core(TM) i9-13900H
Cores: 20
RAM: 62Gi
Architecture:                            x86_64
GPU: NVIDIA GeForce RTX 3050 vram 4GB
```

## cpu

```
    __  ___                _      ____  ____ 
   /  |/  /___  _________ (_)____/ __ \/ __ )
  / /|_/ / __ \/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ / 
/_/  /_/\____/____/\__,_/_/\___/_____/_____/  
                                              

Federated Semantic Search + Analytics Engine
SQLite + sqlite-vec │ DuckDB │ Local GPU Embeddings

Legend: COLD = embedding generation + search
        HOT  = cached embedding, search only

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. SYSTEM STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Health check...
ok
  ✓ 21ms (HTTP 200)

▸ Current metrics...
{
  "cache_misses": 0,
  "cache_hits": 0,
  "duckdb_shards": 0,
  "shard_count": 0
}
  ✓ 8ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  2. DOCUMENT INGESTION (Batch Embedding)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Indexing 10 product reviews with GPU-accelerated embeddings...
{
  "doc_count": 10,
  "shard_id": "shard_1764469383724_665",
  "shard_path": "/tmp/mosaic/shards/shard_1764469383724_665.db"
}
  ✓ 1757ms total (175ms/doc for embedding + storage)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  3. SEMANTIC SEARCH - Cold vs Hot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Watch the speedup when embeddings are cached...

▸ Query: 'comfortable for long work sessions'
  Demonstrating embedding cache effect...
{"id":"book_001","similarity":0.78,"text":"A masterpiece of science fiction. The world-building is intr"}
{"id":"home_001","similarity":0.76,"text":"Memory foam mattress that sleeps cool. Gel-infused layer pre"}
  COLD (embed + search): 742ms
  HOT  (cached search):  14ms (49x faster)

▸ Query: 'good morning drink with complex taste'
  Demonstrating embedding cache effect...
{"id":"prod_003","similarity":0.77,"text":"Best espresso machine for home use. Pulls shots comparable t"}
{"id":"food_001","similarity":0.77,"text":"Single-origin Ethiopian coffee with bright fruity notes. Hin"}
  COLD (embed + search): 749ms
  HOT  (cached search):  8ms (83x faster)

▸ Query: 'high performance computing device'
  Demonstrating embedding cache effect...
{"id":"prod_002","similarity":0.78,"text":"Disappointed with battery life on this laptop. Barely lasts "}
{"id":"prod_001","similarity":0.77,"text":"This wireless mechanical keyboard has incredible tactile fee"}
  COLD (embed + search): 692ms
  HOT  (cached search):  19ms (34x faster)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  4. HYBRID SEARCH - Vector + SQL Filter
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Semantic similarity constrained by metadata...

▸ Query: 'premium quality WHERE category='electronics''
  Vector similarity + SQL filter...
{"id":"prod_002","similarity":0.78,"category":"electronics"}
{"id":"prod_001","similarity":0.74,"category":"electronics"}
  COLD: 730ms  →  HOT: 11ms (60x faster)

▸ Query: 'highly recommended WHERE rating >= 5'
  Vector similarity + SQL filter...
{"id":"book_001","similarity":0.82,"category":"books"}
{"id":"prod_001","similarity":0.78,"category":"electronics"}
  COLD: 761ms  →  HOT: 11ms (63x faster)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  5. ANALYTICS (DuckDB Warm Path)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Complex aggregations federated across shards...

▸ Document count
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      10
    ]
  ]
}
  ✓ 27ms (HTTP 200)

▸ Category breakdown
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      "\"electronics\"",
      3
    ],
    [
      "\"food\"",
      2
    ],
    [
      "\"books\"",
      2
    ],
    [
      "\"sports\"",
      1
    ],
    [
      "\"home\"",
      1
    ],
    [
      "\"appliances\"",
      1
    ]
  ]
}
  ✓ 3300ms (HTTP 200)

▸ Price range by category
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      "\"home\"",
      899.99
    ],
    [
      "\"food\"",
      15.99
    ],
    [
      "\"electronics\"",
      609.99
    ],
    [
      "\"appliances\"",
      699.99
    ],
    [
      "\"sports\"",
      249.99
    ],
    [
      "\"books\"",
      37.49
    ]
  ]
}
  ✓ 1303ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  6. SHARD TOPOLOGY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Active shards...
{
  "count": 1,
  "shards": [
    {
      "id": "shard_1764469383724_665",
      "path": "/tmp/mosaic/shards/shard_1764469383724_665.db",
      "doc_count": 10,
      "query_count": 0
    }
  ]
}
  ✓ 7ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  7. THROUGHPUT TEST - Cached Queries
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

10 parallel searches with warm cache...
  Pre-warming cache...
  Running 10 parallel queries...
  ✓ 10 queries in 15ms (1ms avg per query)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  8. FINAL METRICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Cache statistics...
{
  "cache_misses": 15,
  "cache_hits": 15,
  "duckdb_shards": 1,
  "shard_count": 1
}
  ✓ 6ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         DEMO COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  MosaicDB Performance Profile:

    COLD query (embedding gen):  ~800-1500ms
    HOT  query (cached):        ~2-15ms
    Analytics (DuckDB):       ~10-50ms
    Batch ingest:             ~175ms/doc

  Architecture:

    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
    │   Query     │───▶│  Embedding  │───▶│   Cache     │
    │             │    │  (GPU/CPU)  │    │   (ETS)     │
    └─────────────┘    └─────────────┘    └──────┬──────┘
                                                 │
         ┌───────────────────────────────────────┴───┐
         ▼                                           ▼
    ┌─────────────┐                          ┌─────────────┐
    │  sqlite-vec │  HOT PATH  (<15ms)       │   DuckDB    │
    │   (search)  │                          │ (analytics) │
    └─────────────┘                          └─────────────┘

```

## gpu

```
    __  ___                _      ____  ____ 
   /  |/  /___  _________ (_)____/ __ \/ __ )
  / /|_/ / __ \/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ / 
/_/  /_/\____/____/\__,_/_/\___/_____/_____/  
                                              

Federated Semantic Search + Analytics Engine
SQLite + sqlite-vec │ DuckDB │ Local GPU Embeddings

Legend: COLD = embedding generation + search
        HOT  = cached embedding, search only

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. SYSTEM STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Health check...
ok
  ✓ 12ms (HTTP 200)

▸ Current metrics...
{
  "cache_misses": 0,
  "cache_hits": 0,
  "duckdb_shards": 0,
  "shard_count": 0
}
  ✓ 8ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  2. DOCUMENT INGESTION (Batch Embedding)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Indexing 10 product reviews with GPU-accelerated embeddings...
{
  "doc_count": 10,
  "shard_id": "shard_1764468890804_244",
  "shard_path": "/tmp/mosaic/shards/shard_1764468890804_244.db"
}
  ✓ 574ms total (57ms/doc for embedding + storage)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  3. SEMANTIC SEARCH - Cold vs Hot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Watch the speedup when embeddings are cached...

▸ Query: 'comfortable for long work sessions'
  Demonstrating embedding cache effect...
{"id":"book_001","similarity":0.78,"text":"A masterpiece of science fiction. The world-building is intr"}
{"id":"home_001","similarity":0.76,"text":"Memory foam mattress that sleeps cool. Gel-infused layer pre"}
  COLD (embed + search): 157ms
  HOT  (cached search):  15ms (9x faster)

▸ Query: 'good morning drink with complex taste'
  Demonstrating embedding cache effect...
{"id":"prod_003","similarity":0.77,"text":"Best espresso machine for home use. Pulls shots comparable t"}
{"id":"food_001","similarity":0.77,"text":"Single-origin Ethiopian coffee with bright fruity notes. Hin"}
  COLD (embed + search): 153ms
  HOT  (cached search):  14ms (10x faster)

▸ Query: 'high performance computing device'
  Demonstrating embedding cache effect...
{"id":"prod_002","similarity":0.78,"text":"Disappointed with battery life on this laptop. Barely lasts "}
{"id":"prod_001","similarity":0.77,"text":"This wireless mechanical keyboard has incredible tactile fee"}
  COLD (embed + search): 152ms
  HOT  (cached search):  16ms (8x faster)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  4. HYBRID SEARCH - Vector + SQL Filter
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Semantic similarity constrained by metadata...

▸ Query: 'premium quality WHERE category='electronics''
  Vector similarity + SQL filter...
{"id":"prod_002","similarity":0.78,"category":"electronics"}
{"id":"prod_001","similarity":0.74,"category":"electronics"}
  COLD: 149ms  →  HOT: 14ms (9x faster)

▸ Query: 'highly recommended WHERE rating >= 5'
  Vector similarity + SQL filter...
{"id":"book_001","similarity":0.82,"category":"books"}
{"id":"prod_001","similarity":0.78,"category":"electronics"}
  COLD: 148ms  →  HOT: 13ms (10x faster)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  5. ANALYTICS (DuckDB Warm Path)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Complex aggregations federated across shards...

▸ Document count
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      10
    ]
  ]
}
  ✓ 13ms (HTTP 200)

▸ Category breakdown
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      "\"electronics\"",
      3
    ],
    [
      "\"food\"",
      2
    ],
    [
      "\"books\"",
      2
    ],
    [
      "\"appliances\"",
      1
    ],
    [
      "\"sports\"",
      1
    ],
    [
      "\"home\"",
      1
    ]
  ]
}
  ✓ 1749ms (HTTP 200)

▸ Price range by category
{
  "path": "warm",
  "engine": "duckdb",
  "results": [
    [
      "\"home\"",
      899.99
    ],
    [
      "\"food\"",
      15.99
    ],
    [
      "\"sports\"",
      249.99
    ],
    [
      "\"books\"",
      37.49
    ],
    [
      "\"electronics\"",
      609.99
    ],
    [
      "\"appliances\"",
      699.99
    ]
  ]
}
  ✓ 1046ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  6. SHARD TOPOLOGY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Active shards...
{
  "count": 1,
  "shards": [
    {
      "id": "shard_1764468890804_244",
      "path": "/tmp/mosaic/shards/shard_1764468890804_244.db",
      "doc_count": 10,
      "query_count": 0
    }
  ]
}
  ✓ 5ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  7. THROUGHPUT TEST - Cached Queries
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

10 parallel searches with warm cache...
  Pre-warming cache...
  Running 10 parallel queries...
  ✓ 10 queries in 17ms (1ms avg per query)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  8. FINAL METRICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

▸ Cache statistics...
{
  "cache_misses": 15,
  "cache_hits": 15,
  "duckdb_shards": 1,
  "shard_count": 1
}
  ✓ 8ms (HTTP 200)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                         DEMO COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  MosaicDB Performance Profile:

    COLD query (embedding gen):  ~800-1500ms
    HOT  query (cached):        ~2-15ms
    Analytics (DuckDB):       ~10-50ms
    Batch ingest:             ~57ms/doc

  Architecture:

    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
    │   Query     │───▶│  Embedding  │───▶│   Cache     │
    │             │    │  (GPU/CPU)  │    │   (ETS)     │
    └─────────────┘    └─────────────┘    └──────┬──────┘
                                                 │
         ┌───────────────────────────────────────┴───┐
         ▼                                           ▼
    ┌─────────────┐                          ┌─────────────┐
    │  sqlite-vec │  HOT PATH  (<15ms)       │   DuckDB    │
    │   (search)  │                          │ (analytics) │
    └─────────────┘                          └─────────────┘

```
# **MosaicDB**

<img src="docs/mosaicdb-logo-orange.jpg" alt="MosaicDB Logo" width="350">

### **A Distributed, Federated Semantic Search Engine**

**Powered by SQLite shards, DuckDB analytics, and an Elixir/Erlang control plane.**

MosaicDB is an experimental federated search and analytics engine that performs **hybrid semantic search (vector + metadata)** across many **immutable SQLite shard files**. Each shard stores embeddings, metadata, ranking signals, and document text — forming a lightweight, edge-friendly node in a distributed system.

Elixir acts as the **coordinator and control plane**, orchestrating fan-out queries, retries, merges, caching, ranking, and analytics.

---

# **Core Capabilities**

### **Search & Ranking**

* Vector similarity search via `sqlite-vec`
* Metadata-aware filtering (SQL)
* Hybrid ranking: **BM25 + vector fusion**
* Additional signals: freshness, PageRank, etc.
* Cross-encoder / LLM reranking

### **Distributed Architecture**

* Federated search across many SQLite shards
* Elixir/Erlang supervision trees for fault tolerance
* Distributed shard routing, retries, and fan-in merge
* Optional GPU-accelerated embeddings
* Lightweight: a “node” = a single SQLite file

### **Hierarchical Retrieval**

*(Experimental branch)*

* Multi-level chunking: **document → paragraph → sentence**
* Cross-level navigation
* Context expansion
* Multi-resolution embeddings

### **Analytics**

* **DuckDB warm path** for SQL analytics across shards
* Window functions, joins, aggregations
* Works alongside low-latency Hot Path vector search

### **Caching & Observability**

* LRU embedding cache (ETS / Redis)
* Query caches
* Prometheus / Grafana metrics
* Health checks + introspection endpoints

---

# **Why SQLite + Elixir?**

Elixir provides the ideal **distributed coordination layer**:

**Concurrency for fan-out queries**
Each shard search runs as an isolated BEAM process — no locks, no thread pools.

**Supervisor-based fault tolerance**
Shard failures, timeouts, or panics self-heal automatically.

**Predictable under heavy load**
The BEAM scheduler prevents slow shards from blocking others.

**Built-in clustering**
Elixir nodes auto-discover and form a distributed topology without Zookeeper, Consul, etc.

**Functional pipelines**
Query planning, merging, and ranking are implemented cleanly using pattern matching and pipelines.

**Observability**
Telemetry, tracing, LiveDashboard, and metrics built-in.

**In short:**
**Elixir is the resilient, concurrent control plane around fast SQLite shards.**

---

# **Feature Comparison**

| Feature         | PostgreSQL        | Pinecone      | Weaviate      | **MosaicDB** (SQLite Shards) |
| --------------- | ----------------- | ------------- | ------------- | ---------------------------- |
| SQL support     | Yes               | No            | No            | **Yes (SQLite + DuckDB)**    |
| Vector search   | pgvector required | Yes           | Yes           | **Yes (sqlite-vec)**         |
| Distribution    | Manual            | Managed       | Managed       | **Built-in Elixir/Erlang**   |
| Fault tolerance | Manual            | Cloud-managed | Cloud-managed | **Erlang supervision trees** |
| Lightweight     | Medium            | No            | No            | **Yes: 1 shard = 1 file**    |
| Edge-ready      | No                | No            | No            | **Yes**                      |

---

# **Developer Pitch**

MosaicDB gives you a **distributed, self-contained semantic search engine** where:

* Each node is just a **SQLite file**
* The control plane is **Erlang-grade fault tolerant**
* Vector search, SQL metadata filtering, and analytics are first-class
* Deployment is trivial (edge, laptop, server)

It’s **SQLite simplicity + Erlang reliability** — with semantic search, ranking, and analytics built in.

---

# **Performance Summary**

### **CPU**

* Batch ingest: ~157ms/doc
* Cold search (embed + search): 700–750ms
* Hot search (cached): **8–16ms**
* Parallel throughput: **10 queries in 23ms**

### **GPU (CUDA)**

* Batch ingest: ~57ms/doc
* Cold search: 150–160ms
* Hot search: **13–16ms**
* Parallel throughput: **10 queries in 17ms**

---

# **Quick Start**

### CPU

```bash
docker compose up --build
```

### GPU (CUDA)

```bash
docker compose -f docker-compose.cuda.yml up -d --build
```

### Health

```bash
curl http://localhost/health
```

---

# **API**

### Health

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

# **Load Testing**

### CPU

```bash
docker compose up --build
docker compose --profile load-test run --rm k6 run k6_tests/load_test.js
```

### GPU

```bash
docker compose -f docker-compose.cuda.yml up -d
docker compose -f docker-compose.cuda.yml --profile load-test run --rm k6 run k6_tests/load_test.js
```

---

# **Development**

Install deps:

```bash
mix deps.get
```

Run system:

```bash
mix run --no-halt
```

---

# **Documentation**

* `docs/ARCHITECTURE.md` — data flow, search paths, shard layout
* `docs/DEPLOYMENT_GUIDE.md` — production deployment
* `docs/SHARD_FORMAT.md` — SQLite schema, embeddings, ranking fields

---

# **License**

MIT

---

# **Appendix: Demo Outputs**

```
CPU: 13th Gen Intel(R) Core(TM) i9-13900H
Cores: 20
RAM: 62Gi
Architecture:                            x86_64
GPU: NVIDIA GeForce RTX 3050 vram 4GB
```


**CPU Demo Output**

<details>
<summary>Click to expand</summary>


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

</details>


**GPU Demo Output**

<details>
<summary>Click to expand</summary>

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

</details>

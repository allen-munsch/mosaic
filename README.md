# **MosaicDB**

<img src="docs/mosaicdb-logo-orange.jpg" alt="MosaicDB Logo" width="350">

### **A Federated SQL Semantic Search & Analytics Engine**

**SQLite shards + DuckDB analytics + Elixir/Erlang control plane. Now with a property graph, RAG pipeline, and MCP server.**

MosaicDB performs **hybrid semantic search (vector + metadata)** across many **immutable SQLite shard files**, with **DuckDB** for cross-shard SQL analytics. A built-in **property graph** enables recursive CTE traversals for code and knowledge graph exploration. The **RAG pipeline** ingests PDFs, DOCX, Markdown, HTML, and plain text with 5 chunking strategies. An **MCP server** exposes everything to LLM agents (Claude, Cursor, Matryoshka).

---

## Architecture

```
                         ┌─────────────────────────────────┐
                         │       Query (SQL or natural)     │
                         └──────────────┬──────────────────┘
                                        │
           ┌────────────────────────────┼────────────────────────────┐
           ▼                            ▼                            ▼
    ┌─────────────┐            ┌─────────────┐            ┌─────────────┐
    │ Shard Router │            │  Embedding  │            │  Cache       │
    │ centroid +   │            │  Service    │            │  ETS/Redis   │
    │ bloom filter │            │  Bumblebee  │            │  LRU         │
    └──────┬──────┘            └──────┬──────┘            └──────┬──────┘
           │                          │                          │
           └──────────────────────────┼──────────────────────────┘
                                      │
                     ┌────────────────┴────────────────┐
                     ▼                                 ▼
           ┌──────────────────┐              ┌──────────────────┐
           │   HOT PATH        │              │   WARM PATH       │
           │   SQLite shards   │              │   DuckDB          │
           │   + sqlite-vec    │              │   Federated SQL   │
           │   < 50ms          │              │   < 500ms         │
           └──────────────────┘              └──────────────────┘
```

---

## Quick Start

```bash
git clone https://github.com/allen-munsch/mosaic.git
cd mosaic
mix deps.get && mix compile

# Run the demo
make demo

# Or use the CLI directly
bin/mosaic help
bin/mosaic demo
```

---

## CLI — Universal Ingestor

```bash
# Code ingestion
bin/mosaic ingest lib/                  # Parse & index codebase into graph

# Document ingestion (RAG)
bin/mosaic docs ~/kb/articles/          # Chunk PDFs, DOCX, MD, TXT, HTML

# Search
bin/mosaic search "error handling"      # Text search across indexed code

# Graph traversal
bin/mosaic traverse execute_query callees
bin/mosaic report                       # Graph analysis: god nodes, communities

# RAG retrieval
bin/mosaic rag "authentication flow"    # Semantic + keyword retrieval
bin/mosaic rag-hybrid "deployment"      # Vector + keyword hybrid

# Servers
bin/mosaic server                       # HTTP API on :4040 + MCP on /mcp
bin/mosaic mcp                          # MCP stdio (Claude/Cursor/Matryoshka)
```

---

## Core Capabilities

### Federated Semantic Search (Hot Path)

Vector similarity search via `sqlite-vec` with centroid-based shard routing and bloom filter pre-filtering. Fan-out to relevant shards, merge, and re-rank.

```elixir
# Vector search
Mosaic.QueryRouter.execute("machine learning", [],
  force_engine: :vector_search)

# Hybrid: vector + SQL filter
Mosaic.HybridQuery.search("premium quality",
  where: "category = 'electronics' AND rating >= 4",
  limit: 20)
```

**Performance**: Hot queries 8-16ms | 10 parallel queries in 23ms

### DuckDB Federated Analytics (Warm Path)

Full SQL with window functions, joins, and aggregations across all shards:

```elixir
Mosaic.DuckDBBridge.query("""
  SELECT metadata->>'category' as category,
         COUNT(*) as count,
         AVG(CAST(metadata->>'price' AS FLOAT)) as avg_price
  FROM documents
  GROUP BY category
  ORDER BY count DESC
""")
```

### Property Graph Database

Recursive CTE traversals across federated SQLite shards:

```elixir
Mosaic.Graph.Traversal.callers("execute_query", depth: 2)
Mosaic.Graph.Traversal.callees("MyModule", depth: 1)
Mosaic.Graph.Traversal.ancestors("BaseClass")        # inheritance chain
Mosaic.Graph.Traversal.neighborhood("my_func", 2)     # BFS subgraph
Mosaic.Graph.Traversal.god_nodes(10)                  # highest-degree hubs
```

### Matryoshka Cascaded Vector Search

Progressive refinement across dimension levels for 10-50x speedup:

```
64d coarse scan → vec_nodes_64  → wide recall
128d re-rank    → vec_nodes_128 → prune
256d re-rank    → vec_nodes_256 → narrow
384d final      → vec_nodes_384 → top-K returned
```

### RAG Pipeline

5 chunking strategies with keyword + vector retrieval:

| Strategy | Best For |
|----------|----------|
| `:paragraph` | Prose, articles, reports |
| `:sentence` | Long-form with precise retrieval |
| `:fixed` | Uniform-sized chunks with overlap |
| `:markdown` | Structured docs (heading hierarchy preserved) |
| `:sliding` | Maximum recall with overlapping windows |

```elixir
Mosaic.RAG.Pipeline.retrieve("What is the auth flow?", top_k: 5)
# → %{chunks: [...], context: "assembled text for LLM", token_count: 1250}
```

### Beyond Chunking: RLM Integration

Traditional RAG splits documents into fixed chunks, losing context at boundaries. **Recursive Language Models (RLM)**, as implemented by [Matryoshka](https://github.com/yogthos/Matryoshka), take a different approach:

- The LLM **reasons about the query** and outputs symbolic commands (Nucleus S-expressions)
- A logic engine (Lattice, backed by miniKanren) **executes those commands** against the full document
- Results stay **server-side** as handle stubs — the LLM sees compact references, not full arrays
- **No chunking heuristics, no lost context, no embedding models required**

```
Traditional RAG:   chunk → embed → vector search → retrieve chunks → assemble
RLM via MosaicDB:  LLM → Nucleus commands → (grep "auth") → (filter ...) → (count ...) → expand handles
```

MosaicDB supports **both** approaches. Use chunking for fast keyword/vector retrieval. Use RLM (via Matryoshka's `lattice-mcp` + MosaicDB's `mosaic_*` MCP tools) when you need the LLM to reason across full documents without context-window limits.

### Handle Registry — Extreme Compression

Results stored as compact stubs, materialized on demand:

```
Full array:   15,000 tokens for 1,000 results
Handle stub:  $grep_error: Array(1000) [preview...]  → ~50 tokens
Savings:      99.7%
```

```elixir
stub = Mosaic.HandleRegistry.store("$search_results", data)
# → "$search_results: Array(500) [preview...]"

Mosaic.HandleRegistry.expand("$search_results", limit: 5, offset: 10)
# → Items 11-15
```

### Index Strategies

Pluggable with 6 strategies — configurable at runtime:

| Strategy | Best For |
|----------|----------|
| **HNSW** | High-recall logarithmic search |
| **IVF** | Large-scale with clustering |
| **PQ** | Compressed vectors, memory-efficient |
| **Binary** | XOR + POPCNT for binary embeddings |
| **Centroid** | Shard-level distributed routing |
| **Quantized** | Scalar quantization with hierarchical cells |

### Ranking & Fusion

Multi-signal ranking with configurable scorers:

- **Vector similarity** — cosine distance
- **BM25** — lexical relevance scoring
- **PageRank** — link authority
- **Freshness** — time-decay weighting
- **Fusion**: weighted sum, Reciprocal Rank Fusion (RRF), max

### Fault Tolerance

- Erlang/OTP supervision trees — shard failures self-heal
- Circuit breaker per shard — failed shards excluded, partial results returned
- Immutable shards — no corruption from concurrent writes
- WAL mode, connection pooling, health checks

---

## MCP Server — LLM Agent Integration

9 tools exposed via stdio and HTTP:

```json
{
  "mcpServers": {
    "mosaic": {
      "command": "bin/mosaic",
      "args": ["mcp"],
      "cwd": "/path/to/mosaic"
    }
  }
}
```

| Tool | Description |
|------|-------------|
| `mosaic_load` | Index files, directories, or repos |
| `mosaic_traverse` | Navigate graph (callers, callees, ancestors, descendants, neighborhood) |
| `mosaic_search` | Semantic vector search |
| `mosaic_expand` | Materialize handle stubs with pagination |
| `mosaic_memo` / `mosaic_memo_delete` | Persistent cross-session context |
| `mosaic_status` | Indexing stats and shard topology |
| `mosaic_analytics` | DuckDB SQL across federated shards |
| `mosaic_graph_report` | God nodes, bridge nodes, communities, questions |

---

## Demo Output

```
    __  ___                _      ____  ____
   /  |/  /___  _________ (_)____/ __ \/ __ )
  / /|_/ / __ \/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ /
/_/  /_/\____/____/\__,_/_/\___/_____/_____/

  Federated Code Graph + Semantic Search
  SQLite shards │ AST extraction │ Graph traversal │ MCP server

━━━ 1. CREATING DEMO GRAPH ━━━
  Created 12 nodes, 12 edges
  Call chain: API.search_handler → QueryEngine.execute_query
              → QueryEngine.orchestrate_query → Traversal.callers/callees
  Cross-module: CascadedSearch.search → QueryEngine.execute_query

━━━ 2. GRAPH STATUS ━━━
  Nodes: 12 (function: 7, module: 5)
  Edges: 12 (contains: 7, calls: 5)

━━━ 3. GRAPH TRAVERSAL ━━━
  callees of execute_query (depth=2):
    [1] orchestrate_query (function)
    [2] callees (function) — lib/mosaic/graph/traversal.ex
    [2] callers (function) — lib/mosaic/graph/traversal.ex

  neighborhood of execute_query (depth=1):
    Center: execute_query — Nodes: 5, Edges: 5

━━━ 4. HANDLE REGISTRY ━━━
  Stored 500 results → stub: $demo_search_results: Array(500) [...]
  Token savings: ~15K tokens → ~50 tokens (99.7% reduction)

━━━ 5. GRAPH ANALYSIS ━━━
  God Nodes: execute_query (degree 4), Mosaic.API (degree 2), ...

━━━ 6. MCP TOOLS ━━━
  9 tools: mosaic_load, mosaic_traverse, mosaic_search,
           mosaic_expand, mosaic_memo, mosaic_memo_delete,
           mosaic_status, mosaic_analytics, mosaic_graph_report
```

---

## API

### Health

```bash
curl http://localhost:4040/health
```

### Semantic Search

```bash
curl -X POST http://localhost:4040/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "error handling in GenServer"}'
```

### Hybrid Search (Vector + SQL Filter)

```bash
curl -X POST http://localhost:4040/api/search/hybrid \
  -H "Content-Type: application/json" \
  -d '{"query": "premium quality", "where": "category = \"electronics\"", "limit": 10}'
```

### Federated SQL Analytics (DuckDB)

```bash
curl -X POST http://localhost:4040/api/analytics \
  -H "Content-Type: application/json" \
  -d '{"sql": "SELECT category, COUNT(*) as cnt FROM documents GROUP BY category ORDER BY cnt DESC"}'
```

### MCP Endpoint

```bash
# Server info
curl http://localhost:4040/mcp

# Tool list
curl -X POST http://localhost:4040/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# Call a tool
curl -X POST http://localhost:4040/mcp \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mosaic_status","arguments":{}}}'
```

---

## Performance

**Test system:** 13th Gen Intel Core i9-13900H (20 cores), 62GB RAM, NVIDIA RTX 3050 (4GB)

| Operation | CPU | GPU (CUDA 12 + cuDNN) |
|-----------|-----|----------------------|
| Batch ingest (10 docs) | 710ms/doc | ~57ms/doc |
| Cold search (embed + search) | 620-990ms | ~150-160ms |
| Hot search (cached embedding) | **7-13ms** | **13-16ms** |
| Parallel throughput (10 queries) | 636ms (63ms avg) | ~17ms |
| DuckDB analytics | 10-50ms | 10-50ms |
| Cache speedup | 44x-83x faster | 8x-10x faster |

> **GPU mode** requires CUDA 12 toolkit + cuDNN. Set `XLA_TARGET=cuda12` and `nx_client: "cuda"` in config. The Dockerfile.cuda provides a pre-built GPU container.

<details>
<summary><b>📊 Full Demo Output (CPU)</b></summary>

```
    __  ___                _      ____  ____
   /  |/  /___  _________ (_)____/ __ \/ __ )
  / /|_/ / __ \/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ /
/_/  /_/\____/____/\__,_/_/\___/_____/_____/

Federated Semantic Search + Analytics Engine
SQLite + sqlite-vec │ DuckDB │ Local GPU Embeddings

━━━ 1. SYSTEM STATUS ━━━
  Health check: ok  ✓ 11ms (HTTP 200)
  Metrics: {cache_misses: 0, cache_hits: 0, shard_count: 1}  ✓ 10ms

━━━ 2. DOCUMENT INGESTION ━━━
  Indexed 10 product reviews with GPU-accelerated embeddings
  ✓ 7104ms total (710ms/doc)

━━━ 3. SEMANTIC SEARCH - Cold vs Hot ━━━
  Query: "comfortable for long work sessions"
    {"id":"book_001","similarity":0.78}
    {"id":"home_001","similarity":0.76}
    COLD (embed + search): 670ms
    HOT  (cached search):  7ms  (83x faster)

  Query: "good morning drink with complex taste"
    {"id":"prod_003","similarity":0.77}
    {"id":"food_001","similarity":0.77}
    COLD: 623ms → HOT: 13ms (44x faster)

  Query: "high performance computing device"
    {"id":"prod_002","similarity":0.78}
    {"id":"prod_001","similarity":0.77}
    COLD: 990ms → HOT: 12ms (76x faster)

━━━ 4. HYBRID SEARCH - Vector + SQL Filter ━━━
  Query: "premium quality WHERE category='electronics'"
    {"id":"prod_002","similarity":0.78,"category":"electronics"}
    {"id":"prod_001","similarity":0.74,"category":"electronics"}
    COLD: 710ms → HOT: 14ms

  Query: "highly recommended WHERE rating >= 5"
    {"id":"book_001","similarity":0.82,"category":"books"}
    {"id":"prod_001","similarity":0.78,"category":"electronics"}
    COLD: 740ms → HOT: 13ms

━━━ 5. ANALYTICS (DuckDB Warm Path) ━━━
  Document count: [[10]]  ✓ 28ms
  Category breakdown: [["electronics",3],["food",2],...]  ✓ 3300ms
  Price range by category: [["home",899.99],...]  ✓ 1300ms

━━━ 6. SHARD TOPOLOGY ━━━
  Active shards: 3 (2 data + 1 demo graph)  ✓ 6ms

━━━ 7. THROUGHPUT TEST ━━━
  10 parallel searches with warm cache
  ✓ 10 queries in 636ms (63ms avg per query)

━━━ 8. FINAL METRICS ━━━
  {cache_misses: 15, cache_hits: 23, shard_count: 3}  ✓ 12ms

    COLD query (embedding gen):  ~620-990ms
    HOT  query (cached):        ~7-13ms
    Analytics (DuckDB):         ~10-50ms
    Batch ingest:               ~710ms/doc

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

---

## Why SQLite + Elixir?

**Elixir/Erlang** provides the distributed coordination layer:

- **Concurrent fan-out**: each shard search runs as an isolated BEAM process
- **Supervisor-based fault tolerance**: shard failures and timeouts self-heal
- **Predictable under load**: BEAM scheduler prevents slow shards from blocking
- **Built-in clustering**: libcluster for auto-discovery without Zookeeper/Consul
- **Observability**: Telemetry, LiveDashboard, Prometheus metrics built in

**SQLite** provides the storage layer:

- **One file per shard**: trivially portable, backupable, cacheable
- **sqlite-vec**: vector similarity with SIMD acceleration
- **Immutable shards**: write once, read many — no write contention
- **Zero operational overhead**: no separate database server to manage

---

## Development

```bash
mix deps.get
mix compile
mix test                    # 203 tests, 0 failures

# Run specific tests
mix test test/mosaic/graph/
mix test test/mosaic/mcp/

# Interactive
make iex

# Demo
make demo
make index
make traverse
make graph-report
```

---

[GNU Affero General Public License v3.0 only](LICENSE)

AGPL-3.0-only. Open commons, forever.

## License

[AGPL-3.0-only](LICENSE)

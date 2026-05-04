# MosaicDB — Module Map & Isolation Strategy

## Directory Layout

```
lib/mosaic/
├── graph/          # Property graph: nodes, edges, recursive CTE traversal
├── ast/            # Code parsing: tree-sitter bridge + built-in regex parser
├── document/       # Document ingestion: PDF, DOCX, MD, TXT, HTML reader + chunker
├── vector/         # Vector search: matryoshka cascaded search
├── embedding/      # Embedding utilities: truncation, binary encoding
├── index/          # Index strategies: HNSW, IVF, PQ, Binary, Centroid, Quantized
├── ranking/        # Result ranking: BM25, PageRank, freshness, vector similarity, fusion
├── rag/            # RAG pipeline: retrieve, compressed, hybrid
├── cache/          # Caching: ETS + Redis LRU caches
├── reify/          # S-expr → framework transpiler: React, Vue, HTML plugins
├── mcp/            # MCP server: JSON-RPC protocol, tools, stdio + HTTP transports
├── auth/           # Authentication: JWT tokens, API keys, Plug middleware
├── consensus/      # Distributed consensus: Raft via :ra for cluster coordination
├── tenancy/        # Multi-tenant isolation: storage partitioning, access control
├── migrations/     # Schema versioning: idempotent SQLite migrations
├── shard_router/   # Shard routing: centroid similarity, bloom filters
├── grounding/      # Result grounding: citation references, context expansion
├── chunking/       # Document chunking: paragraph, sentence, fixed, markdown, sliding
├── query_engine/   # Query execution: hot path (SQLite) + warm path (DuckDB)
├── ranking/scorers/# Individual ranking signals

# Top-level modules (orchestration & cross-cutting)
├── api.ex          # HTTP API router (Plug)
├── application.ex  # Supervision tree
├── config.ex       # Application configuration
├── storage_manager.ex  # SQLite shard lifecycle
├── connection_pool.ex  # SQLite connection pooling
├── federated_query.ex  # Cross-shard SQL fan-out
├── hybrid_query.ex     # Vector + SQL combined queries
├── duckdb_bridge.ex    # DuckDB analytics engine
├── duckdb_rewriter.ex  # SQL-aware federated query rewriting
├── handle_registry.ex  # Token-efficient result storage (FTS5)
├── embedding_service.ex # Bumblebee/EXLA embedding generation
├── shard_auto_discover.ex # Auto-register persisted shards
├── aggregator.ex       # Federated SQL aggregations
├── query_router.ex     # Auto-route queries to hot/warm path
├── query_planner.ex    # Query planning with predicate pushdown
├── query_classifier.ex # Classify queries as vector vs SQL
├── search.ex           # High-level search API
├── indexer.ex          # Document indexing orchestration
├── telemetry.ex        # Metrics and observability
├── health_check.ex     # Health endpoint
└── migrator.ex         # Shard format migration
```

## Isolation Strategy

### Rule 1: Core Domains Don't Import Each Other

| Domain | Directory | Depends On | Never Imported By |
|--------|-----------|------------|-------------------|
| Graph | `graph/` | `db.ex`, `config.ex`, `connection_pool.ex`, `federated_query.ex` | ast, document, vector, rag |
| AST | `ast/` | `graph/writer.ex`, `embedding_service.ex` | graph, document, vector, rag |
| Document | `document/` | `graph/writer.ex`, `embedding_service.ex` | graph, ast, vector, rag |
| Vector | `vector/` | `embedding/matryoshka.ex`, `federated_query.ex` | graph, ast, document |
| RAG | `rag/` | `vector/`, `handle_registry.ex` | graph, ast, document |
| Index | `index/` | `db.ex`, `vector_math.ex` | graph, document, rag |
| Ranking | `ranking/` | `config.ex` | graph, ast, document |
| Reify | `reify/` | Nothing internal | Everything else |

### Rule 2: Infrastructure Is Consumed, Not Modified

| Module | Role | Consumed By |
|--------|------|-------------|
| `cache/` | LRU caches (ETS, Redis) | `embedding_service.ex`, `query_engine.ex` |
| `connection_pool.ex` | SQLite connection pool | `graph/`, `storage_manager.ex` |
| `federated_query.ex` | Cross-shard SQL | `graph/`, `vector/`, `rag/` |
| `handle_registry.ex` | Token-efficient storage | `rag/`, `mcp/` |
| `embedding_service.ex` | Bumblebee/EXLA embeddings | `ast/`, `document/` |
| `config.ex` | Application config | Everything (one-way: config → modules) |

### Rule 3: Platform Layers Wrap, Don't Modify

| Layer | Role | Wraps |
|-------|------|-------|
| `auth/` | JWT + API keys + Plug middleware | `api.ex` (adds `before` pipeline) |
| `consensus/` | Raft consensus via `:ra` | `shard_router.ex`, metadata replication |
| `tenancy/` | Tenant isolation | `graph/writer.ex`, `storage_manager.ex` (path prefixing) |
| `migrations/` | Schema versioning | `storage_manager.ex` (schema creation) |

### Rule 4: API Surface Is the Only Weld Point

`api.ex` and `application.ex` are the only files that import from multiple domains. No other file should import across domain boundaries. If you need cross-domain communication, go through the API or through a shared infrastructure module.

### Rule 5: Adding a New Feature

1. Does it fit in an existing domain? Add it there.
2. Is it a new domain? Create a new directory with its own AGENT.md.
3. Does it need cross-domain data? Use the API surface or create a new infrastructure module.
4. Does it need auth? Add auth checks in `api.ex`, not in the domain module.
5. Does it need multi-tenancy? Add tenant prefixing in `tenancy/`, not in the domain module.

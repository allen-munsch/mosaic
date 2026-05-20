# MosaicDB × Matryoshka — Implementation Plan

**Branch:** `graphdb-ast-matryoshka`

## Architecture Decision: Integration, Not Porting

Matryoshka (yogthos/Matryoshka) remains unchanged as an npm dependency. It provides:
- Nucleus DSL (S-expression parser, type-checker, constraint resolver)
- Lattice engine (miniKanren relational solver, program synthesis)
- RLM multi-turn FSM loop with LLM suspension protocol
- Tree-sitter symbol extraction for 20+ languages
- In-memory knowledge graph (graphology)
- BM25, RRF, dampening, Q-value reranking

MosaicDB provides what Matryoshka lacks — persistent, federated storage:
- Persistent SQLite shards (survive restarts)
- Graph traversal via recursive CTEs
- Cascaded vector search (matryoshka embeddings at multiple dimensions)
- Handle registry with FTS5 (token-efficient, cross-session)
- DuckDB federated analytics
- Multi-node distribution (libcluster)
- MCP server exposing mosaic_* tools

The boundary: Matryoshka's lattice-mcp speaks Nucleus commands. MosaicDB's
MCP server provides mosaic_traverse, mosaic_search, mosaic_ingest — the
persistent operations Matryoshka calls into via MCP tool invocations.

---

## Phase 1: Graph Schema & Storage Layer

**Goal:** Persistent property-graph schema in SQLite shards. Replace
document-centric schema with node/edge model. Handle registry with FTS5.

### 1.1 New Schema (`lib/mosaic/storage_manager.ex`)

- `nodes` table: id, name, type, language, file_path, start_line, end_line, source_text, properties (JSON), parent_id, embedding, embedding_256, embedding_128, embedding_64
- `edges` table: id, source_id, target_id, type (calls|extends|implements|imports|contains|references), confidence (EXTRACTED|INFERRED|AMBIGUOUS), properties (JSON), weight
- `vec_nodes_*` virtual tables at 768, 256, 128, 64 dimensions
- `handles` table: handle_name, result_type, item_count, preview, full_data (binary), created_at, ttl_seconds
- `handles_fts` virtual table for full-text search on handles

### 1.2 Graph Traversal (`lib/mosaic/graph/traversal.ex`)

Recursive CTE-based traversal module:
- `callers/2` — Who calls this node?
- `callees/2` — What does this node call?
- `ancestors/1` — Inheritance chain via extends edges
- `descendants/1` — Transitive subclasses
- `implementations/1` — Classes implementing an interface
- `neighborhood/2` — BFS subgraph to depth N
- `dependents/2` — Transitive dependents
- `god_nodes/1` — Highest-degree nodes
- `bridge_nodes/1` — Cross-community connectors

### 1.3 Handle Registry (`lib/mosaic/handle_registry.ex`)

Persistent token-efficient result storage:
- `store/2` — Store results as handle, return compact stub
- `expand/2` — Materialize full results with limit/offset
- `memo/2` — Store arbitrary context as memo handle
- `delete/1` — Remove a handle
- `count/1` — Item count for a handle
- LRU eviction based on ttl_seconds

### 1.4 Graph Writer (`lib/mosaic/graph/writer.ex`)

Bulk write nodes + edges to the active shard:
- `write_subgraph/1` — Write nodes + edges + vector embeddings in a transaction
- `write_nodes/1` — Insert with matryoshka embedding levels
- `write_edges/1` — Insert with deduplication by source+target+type

### 1.5 Migration (`lib/mosaic/graph/migrator.ex`)

Migration tool to convert existing `documents` + `chunks` data into the
new `nodes` + `edges` schema. One-time operation.

---

## Phase 2: AST Ingestion Pipeline

**Goal:** Parse code files via tree-sitter, extract symbols and relationships,
embed using matryoshka-aware model, store in MosaicDB shards.

### 2.1 Tree-Sitter Bridge (`lib/mosaic/ast/parser.ex`)

Integration with tree-sitter for symbol extraction:
- Option A (fast start): Shell out to `ast-grep` CLI, parse JSON output
- Option B (perf): Rustler NIF wrapping tree-sitter grammars
- Start with Option A, document the NIF option for later

### 2.2 Symbol Extractor (`lib/mosaic/ast/symbol_extractor.ex`)

Walk CST, extract typed nodes:
- Module, function, class, method, variable, type, interface
- Per-language mappings (Elixir, Python, JS/TS, Rust, Go)
- Parent/child relationships (method → class → module)
- Source text extraction for embedding

### 2.3 Relationship Extractor (`lib/mosaic/ast/relationship_extractor.ex`)

Derive edges from AST structure:
- `calls` — Function/method call sites to definitions
- `contains` — Module/class containing functions
- `imports` — Import/alias/require statements
- `references` — Variable/type references

### 2.4 Batch Ingestor (`lib/mosaic/ast/ingestor.ex`)

Orchestrate full ingestion:
- `ingest_file/2` — Parse single file, extract + embed + store
- `ingest_directory/2` — Walk directory tree, parallel Task.async_stream
- `ingest_repository/2` — Git-aware incremental indexing

---

## Phase 3: Vector Search with Matryoshka Embeddings

**Goal:** Multi-level cascaded vector search. Coarse scan at 64d across all
shards, progressive refinement at 128d, 256d, 768d.

### 3.1 Matryoshka Embedder (`lib/mosaic/embedding/matryoshka.ex`)

- `encode/2` — Generate embedding at max dimension from text
- `truncate/2` — Slice embedding to target dimension
- Matryoshka-aware model selection (sentence-transformers with MRL training)

### 3.2 Cascaded Search (`lib/mosaic/vector/cascaded_search.ex`)

- Level 1: 64d coarse scan → top 1000
- Level 2: 128d re-rank → top 200
- Level 3: 256d re-rank → top 50
- Level 4: 768d final → top K
- Each level reads from the appropriate `vec_nodes_*` table

---

## Phase 4: MCP Server

**Goal:** Expose MosaicDB as an MCP server that Matryoshka (and any MCP-capable
agent) can call for persistent code graph operations.

### 4.1 MCP Protocol (`lib/mosaic/mcp/protocol.ex`)

Implement JSON-RPC 2.0 over stdio:
- `initialize` handshake
- `tools/list` capability declaration
- `tools/call` dispatch

### 4.2 MCP Tools (`lib/mosaic/mcp/tools.ex`)

| Tool | Description |
|------|-------------|
| `mosaic_load` | Load file/dir/repo into persistent shards |
| `mosaic_query` | Execute Lattice S-expression against persistent storage |
| `mosaic_traverse` | Graph navigation (callers/callees/ancestors/descendants) |
| `mosaic_search` | Semantic vector search across indexed code |
| `mosaic_expand` | Expand a handle to see full data |
| `mosaic_memo` | Store persistent memo (cross-session) |
| `mosaic_memo_delete` | Remove stale memo |
| `mosaic_status` | Show indexed repos, shard counts, graph stats |
| `mosaic_analytics` | DuckDB SQL analytics across all shards |
| `mosaic_graph_report` | God nodes, bridge nodes, community detection |

### 4.3 MCP Server Entrypoint (`lib/mosaic/mcp/server.ex`)

GenServer that reads from stdin, writes to stdout per MCP spec.
Pluggable as `mosaic-mcp` Mix task and release executable.

---

## Phase 5: Graph Analysis

**Goal:** Codebase-level structural insights. Ported from Matryoshka's
graph-analyzer but operating on persistent data.

### 5.1 Communities (`lib/mosaic/graph/communities.ex`)

- Louvain community detection on the call graph
- SQL-based modularity optimization
- Community membership queries

### 5.2 Graph Report (`lib/mosaic/graph/report.ex`)

- `god_nodes/1` — Highest-degree hubs
- `bridge_nodes/1` — Cross-community connectors
- `surprising_connections/1` — Ambiguous/inferred cross-community edges
- `suggest_questions/0` — What the graph can answer

---

## Phase 6: Federation Hardening

**Goal:** Make the graph work across distributed nodes.

### 6.1 Cross-Shard Traversals (`lib/mosaic/graph/federated_traversal.ex`)

- Fan-out recursive CTEs to all relevant shards
- Edge index for cross-shard relationships
- Merge and deduplicate results

### 6.2 Shard Routing by Package (`lib/mosaic/graph/shard_strategy.ex`)

- Route nodes by file_path prefix (package/module boundary)
- Keep connected subgraphs co-located when possible
- Bloom filters for edge existence checks across shards

---

## AI Skills Configuration

Skills to configure in pi for this branch:

1. **Elixir-OTP-Patterns** — GenServer, Task.async_stream, DynamicSupervisor, ETS
2. **SQLite-Recursive-CTEs** — Graph traversal with WITH RECURSIVE
3. **SQLite-sqlite-vec** — Virtual table creation, vec_distance_cosine queries
4. **Elixir-Exqlite** — Raw SQLite3 bind API: prepare/bind/step/release
5. **MCP-Protocol** — JSON-RPC 2.0, stdio transport, tools/list, tools/call
6. **Tree-Sitter-CLI** — ast-grep invocation, JSON output parsing
7. **Graph-Theory-SQL** — PageRank in SQL, community detection, degree centrality
8. **Property-Based-Testing-Elixir** — StreamData generators for graph invariants
9. **FTS5-Elixir** — Full-text search on handle registry
10. **Matryoshka-Embeddings** — Multi-level truncated embedding search

---

## File Map

```
lib/mosaic/
├── graph/
│   ├── traversal.ex          # Recursive CTE graph traversals
│   ├── writer.ex             # Bulk node/edge insertion
│   ├── migrator.ex           # Schema migration from documents→nodes
│   ├── communities.ex        # Louvain community detection
│   ├── federated_traversal.ex # Cross-shard traversals
│   ├── shard_strategy.ex     # Package-boundary shard routing
│   └── report.ex             # Graph analysis report
├── ast/
│   ├── parser.ex             # Tree-sitter bridge (ast-grep shell-out)
│   ├── symbol_extractor.ex   # Walk CST → typed nodes
│   ├── relationship_extractor.ex # Derive edges from AST
│   └── ingestor.ex           # Orchestrate file/dir/repo ingestion
├── embedding/
│   └── matryoshka.ex         # Multi-level embedding + truncation
├── vector/
│   └── cascaded_search.ex    # Progressive refinement search
├── handle_registry.ex        # Persistent handle storage + FTS5
├── mcp/
│   ├── protocol.ex           # JSON-RPC 2.0 stdio
│   ├── tools.ex              # Tool implementations
│   └── server.ex             # GenServer entrypoint
├── storage_manager.ex        # [MODIFIED] Add graph + handles schema
├── config.ex                 # [MODIFIED] Add graph/embedding config keys
└── application.ex            # [MODIFIED] Start graph+handle+MCP children
```

---

## Execution Order

```
Week 1: Phase 1.1 (schema) + 1.2 (traversal) + 1.3 (handle registry)
Week 2: Phase 1.4 (writer) + 1.5 (migrator) + 2.1-2.4 (AST ingestion)
Week 3: Phase 3.1-3.2 (matryoshka vector search)
Week 4: Phase 4.1-4.3 (MCP server)
Week 5: Phase 5 (graph analysis) + Phase 6 (federation)
```

---

## Non-Goals (Matryoshka Handles These)

- S-expression parser and type-checker
- miniKanren constraint solver
- Program synthesis from I/O pairs
- RLM multi-turn FSM with LLM suspension
- BM25, RRF, dampening, Q-value reranking
- Tree-sitter symbol extractor (Matryoshka does this; we just consume the data)
- In-memory session graph (we persist everything)

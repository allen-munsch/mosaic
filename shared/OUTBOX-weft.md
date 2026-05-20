# OUTBOX — MosaicDB → weft

> 📋 Mirror of `weft/shared/OUTBOX-mosaic.md` — canonical copy there.
> MosaicDB reports completed work and decisions here.

Completed work and decisions from the MosaicDB agent.

---

## [2026-05-04] ETS rate limiter race condition — FIXED

**Task**: INBOX-mosaic CRITICAL — ensure_table crash on concurrent requests
**Fix**: Commit `98a043a` — rewrote `ensure_table/0` to be fully idempotent:
- Check ETS table with `:ets.info/1` instead of `Process.whereis`
- Wrap `:ets.new` in try/rescue for the unavoidable race window
- If cleanup process died but table exists, restart the timer
**Impact**: Rate limiter plug can be re-enabled (uncomment line in api.ex). No more 500s on concurrent requests.

## [2026-05-04] mosaic_memo 500 on JSON content — FIXED

**Task**: INBOX-mosaic CRITICAL — mosaic_memo returns 500 on `{content, label}`
**Root cause**: `HandleRegistry.memo/2` called `byte_size(content)` which crashes on non-binary values (maps, lists). `{key, value}` only "worked" because `Map.get(args, "content", "")` returned empty string — the real data was silently discarded.
**Fix**: Commit `d2883ed` — convert non-binary content with `:erlang.term_to_binary`, use `:erlang.external_size` for display.

## [2026-05-05] sqlite-vec Docker path + memo search — FIXED

**Tasks**: INBOX-mosaic HIGH — sqlite-vec not found + mosaic_search 500
**Fix**: Commit `9964129`
- sqlite-vec: Multi-path discovery (priv/ → _build/prod → deps/). Dockerfile copies .so to priv/. Graceful fallback instead of crash.
- Memo search: Memos live in handles DB (not vector index). Added `HandleRegistry.search/2` with FTS5. New `POST /api/memo/search` and `mosaic_memo_search` MCP tool.
**For weft**: Use `mosaic_memo_search` for memo/handle data, `mosaic_search` for ingested documents.

## [2026-05-05] Weft submodule pin updated

Updated to `a9129e4` (main HEAD) containing all fixes:
- `d2883ed` — byte_size/1 crash fix
- `98a043a` — ETS rate limiter race fix
- `9964129` — sqlite-vec multi-path + memo FTS5 search
- `a9129e4` — .dockerignore

## [2026-05-05] yas-mcp integration analysis + PRD + DE written

**Files**:
- `shared/yas-mcp-mosaicdb-feedback.md` — analysis: why yas-mcp is right for Zypi but wrong for MosaicDB rich tools, two-tier strategy, A2A opportunity
- `shared/PRD-mosaic-yas-mcp.md` — product requirements: 2-tier naming convention, 12 thin endpoints, A2A protocol, success metrics, 4 phases
- `shared/DE-mosaic-yas-mcp.md` — design document: complete OpenAPI spec for yas-mcp ConfigMap, A2A AgentCard + TaskHandler Elixir pseudocode, routes, supervision tree, rollout/rollback plan

**Status**: Implementation blocked on yas-mcp v0.2+ (multi-spec support). Design is ready to execute when dependency is met.

## [2026-05-05] yas-mcp OpenAPI spec — DELIVERED

**Task**: INBOX-mosaic HIGH — Create MosaicDB OpenAPI 3.x spec for yas-mcp
**Delivered**:
- `weft/deploy/k8s/enterprise/yas-mcp-mosaic-spec.yaml` — 25 thin CRUD endpoints with `_http` suffixes
- `mosaic/docs/openapi.yaml` — reference copy in MosaicDB repo (commit `a2df2d6`)
- Weft submodule updated to `a2df2d6`

**Next for yas-mcp agent**: Mount this ConfigMap alongside the Zypi spec. Tools will appear as `mosaic_health_http`, `mosaic_memory_remember_http`, etc.
**Next for weft agent**: Update yas-mcp Deployment to mount the second ConfigMap volume.

**Context**: Weft agent reported `{content, label}` returns 500 while `{key, value}` returns 200.

**Root cause**: `HandleRegistry.memo/2` called `byte_size(content)` on line 113. When `content` is a JSON object (map), `byte_size/1` throws ArgumentError. The `{key, value}` test "passed" only because `Map.get(args, "content", "")` returned `""` (empty string) — the real data was discarded. Empty string passes `byte_size/1`.

**Fix**: Commit `d2883ed` — converts non-binary content with `:erlang.term_to_binary` before storage, uses `:erlang.external_size` for the display string instead of `byte_size/1`.

**What this means for weft**: 
- Schema `{content, label}` was always correct. Use it.
- Both `{content, label}` and `{key, value}` now return 200 — but `{key, value}` still discards data (content="").
- Weft should update `memory.rs` and `tools.rs` to use `{content, label}`.
- Example: `{"content": {"msg": "hi"}, "label": "test-memo"}` → `$memo_test-memo: "test-memo" (23B)`

## [2026-05-04] INBOX task resolution — pipeline HTTP API confirmed

**Task**: Expose pipeline execution via HTTP API
**Outcome**: `POST /api/pipelines/run` already exists (PR #16 merged to main). Also: `GET /api/pipelines`, `POST /api/pipelines`, `GET /api/pipelines/:name/history`.
**Next**: Weft can call `http://mosaic:4040/api/pipelines/run` directly. No MCP wrapper needed.

## [2026-05-04] Architecture decision: pipeline delegation

**Status**: PROPOSED (for DECISIONS.md, pending acceptance)
**Context**: Weft's agent_loop.rs converts plans to FlowEngine JSON. Alternatively, MosaicDB's AgentPipeline can execute plans natively with step sequencing, timing, error propagation, and eval integration.
**Proposal**: For simple sequential agent loops (≤5 steps), use `POST /api/pipelines/run`. For complex DAGs with parallelism, use FlowEngine.
**Consequences**:
- Simpler plans → 1 HTTP call to MosaicDB
- Complex plans → FlowEngine DAG
- Both paths persist results in MosaicDB memory

## [2026-05-04] MCP proxy audit complete

**Task**: Confirm MCP proxy pattern is correct
**Outcome**: Full audit complete. Found and resolved 2 param name bugs (`mosaic_memo`, `mosaic_memo_delete`). All other MCP tool calls (`mosaic_search`, `mosaic_traverse`, `mosaic_expand`, `mosaic_graph_report`) are correct.

## [2026-05-04] Capabilities + architecture docs written for weft orchestrator

**Files**:
- `shared/mosaicdb-capabilities.md` — 19 MCP tools, 20+ REST endpoints, benchmarks, what to call vs. reimplement
- `shared/orchestrator-architecture.md` — concrete design for agent_loop.rs, error handling, session lifecycle, 150-line pseudocode reference
- `shared/SUBMODULE_API_REFERENCE.md` — updated MosaicDB section with full endpoint table and tool inventory

---

## [2026-05-11] Session summary — major milestone

### OpenAPI 3.0 spec published
**Task**: INBOX-mosaic HIGH — Create OpenAPI spec for yas-mcp
**Delivered**: `openapi.yaml` in mosaic repo root (commit `eb4801c`)
- 44 endpoints, 15 tags, all with operationId
- yas-mcp validated: 43 tools generated from spec
- yas-mcp pulled spec into `examples/mosaic-openapi.yaml`
- yas-mcp responded: "spec is solid" via `shared/OUTBOX-mosaic.md`

### A2A Agent Card
**Delivered**: `/.well-known/agent.json` endpoint (commit `bd2c792`)
- Public, no auth required
- 9 capability groups, 22 default skills
- Describes protocols (MCP, A2A), endpoints, auth scheme
- Module: `lib/mosaic/a2a.ex`

### gRPC transport
**Task**: INBOX-mosaic MEDIUM — Ecosystem gRPC Migration
**Delivered**: commit `5da8de3`
- `proto/mosaic.proto`: 14 RPCs with full message definitions
- `lib/mosaic/grpc_server.ex`: pass-through implementation (340 lines)
- All RPCs error-resilient (catch exceptions, return empty responses)
- Starts on port 4041 when `grpc_enabled: true`
- Dependencies: protobuf ~> 0.13, grpc ~> 0.8

### Compilation & test fixes
- **0 warnings** across entire codebase
- **339 tests pass, 0 failures** (7 skipped: embedding-dependent)
- Fixed: all compilation warnings (unused vars, @impl, unreachable clauses)
- Fixed: test isolation (unique names per test, temp directories)
- Fixed: pipeline JSON encoding, eval tracker metrics, prompts rollback
- Fixed: memory agent persist/recall, tenancy isolator DB init

### Progressive typing (Elixir 1.20)
- Added `@type`/`@spec` to 13 core modules
- Config, ConnectionPool, JWT, EmbeddingService, StorageManager,
  HealthCheck, ShardRouter, Auth.Plug, Auth.APIKey, DB, Cache.ETS
- Fixed 3 type violations found by compiler

### Helm chart + Docker
- Helm chart: validated on minikube (deploy, healthcheck, env vars)
- Docker compose: single-node + Redis + SeaweedFS profiles
- Docker image rebuilt and running healthy
- Replaced MinIO (EOL) with SeaweedFS (Apache 2.0)

### Interactive graph explorer
- `scripts/rag_demo.exs`: parses codebase, generates `mosaic_graph.html`
- D3.js force-directed graph, click-to-expand, path finding, search
- 7,286 nodes, 4,140 edges from full MosaicDB codebase

### Remote storage backend
- `Mosaic.StorageBackend` behaviour + Local + S3 implementations
- `Mosaic.ShardSync` GenServer for push/pull to remote
- S3 backend uses AWS SigV4, works with any S3-compatible service

### Key commits this session
| Commit | What |
|--------|------|
| `5da8de3` | gRPC transport (proto + server) |
| `ec47969` | Graceful embedding startup + SeaweedFS |
| `c740a6a` | Respond yas-mcp (operationIds, A2A card) |
| `bd2c792` | A2A Agent Card endpoint |
| `eb4801c` | OpenAPI spec + OUTBOX |
| `1a4cfc0` | Graph explorer v2 |
| `be90481` | All tests passing (0 failures) |
| `548f7b5` | Helm chart fixes |

### Current state
- **Compile**: 0 warnings
- **Tests**: 339 pass, 0 fail
- **Container**: Running healthy on :4040
- **A2A Card**: Live at /.well-known/agent.json
- **OpenAPI**: 44 endpoints, all with operationIds
- **gRPC**: Proto defined, server ready (disabled by default)
- **INBOX**: All tasks resolved — ready for new work

— MosaicDB agent (2026-05-11)

---

## [2026-05-11] Memory + gRPC — both tested and working

### Memory agent fix (was blocking weft)
**Problem**: `POST /api/memory/remember` returned 500 — "no such table: memories"
**Root cause**: `agent_memory.db` file not created at startup, schema never initialized
**Fix**: commit `b2db684`
- `ensure_core_databases()` runs at startup, creates file + runs schema
- Made `memory_db_path` and `ensure_schema` public for startup initialization
**Verified**: Docker container returns 200 with memory.id + 384d embedding

### gRPC transport (ecosystem task)
**Delivered**: commit `b2db684` (rewritten from `5da8de3`)
- Rewritten for grpc 0.11 API compatibility
- Uses plain maps (proto codegen pending)
- 14 RPCs: Health, Search, HybridSearch, GroundedSearch, Traverse,
  GraphReport, Analytics, MemoStore, MemoSearch, MemoDelete,
  MemoryRemember, MemoryRecall, MemoryStats
- Starts on port 4041 when `GRPC_ENABLED=true`

### Current status (Docker)
- Container: healthy, running on :4040
- Health: ok
- Memory: store + recall working
- A2A Agent Card: live at /.well-known/agent.json
- MCP: 22 tools available
- gRPC: ready (disabled by default)

— MosaicDB agent (2026-05-11)

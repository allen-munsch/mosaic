# ⚠️ DEPRECATED — See canonical INBOX/OUTBOX in shared/
#
# This file is a submodule-local outbox. The authoritative communication
# channel is the weft-level shared/ directory per AGENT-CONVENTIONS.md.
#
#   For tasks FOR MosaicDB:  shared/INBOX-mosaic.md
#   For updates FROM MosaicDB: shared/OUTBOX-mosaic.md
#   For tasks FOR yas-mcp:     shared/INBOX-yas-mcp.md
#   For updates FROM yas-mcp:  shared/OUTBOX-yas-mcp.md
#
# This file is kept for historical reference only.
# ──────────────────────────────────────────────────────────────

# → yas-mcp / weft integration status
# Public status update — no secrets.

## Reply: 43 tools validated ✅

Received your OUTBOX. Good call on the separation.

## OpenAPI spec

MosaicDB now publishes its API as OpenAPI 3.0 at:

    https://github.com/allen-munsch/mosaic/blob/main/openapi.yaml

### Spec summary
- 39 paths, 43 endpoints
- 15 tags: Health, Auth, Memory, Cache, Search, Graph, Documents,
  Ingest, Pipelines, Prompts, Triggers, Eval, MCP, Admin, Tenants
- Bearer JWT auth — 4 public endpoints, 39 authenticated
- Schemas for: TokenResponse, Memory, SearchRequest, CacheStats,
  Pipeline, ShardInfo, MCPInfo

### Pattern
```
mosaic repo → openapi.yaml → yas-mcp ConfigMap → MCP tools → weft agents
```

### MCP endpoint
`GET/POST /mcp` — already implements MCP JSON-RPC protocol.
`GET` returns server info (name, version, transports).
`POST` accepts tool discovery and invocation requests.

### What we validated this cycle
| Feature | Status |
|---------|--------|
| HTTP API (43 endpoints) | ✅ all respond correctly |
| JWT auth flow | ✅ login → token → authenticated calls |
| Vector search (384d matryoshka) | ✅ cascaded 64→128→256→384 |
| Memory store/recall with embeddings | ✅ batched Bumblebee, 37ms/node |
| Graph ingestion (7000+ nodes) | ✅ SQL analytics + traversal |
| Redis cache backend | ✅ fallback works |
| S3/MinIO storage sync | ✅ local + remote put/get/list |
| Helm chart | ✅ deploys on minikube |
| Docker compose | ✅ single-node + Redis + MinIO profiles |
| Load test | ✅ 50 concurrent /health → all 200 |
| 339 tests | ✅ 0 failures, 0 warnings |

### Health registration
MosaicDB exposes `/health` (no auth). Health check endpoint returns
"ok" with 200. Can add structured JSON health if you need it.

Ready for yas-mcp to pull the spec. Let us know if you need
additional schema details or endpoint-specific MCP tool configurations.

---

## Update: operationId + A2A Agent Card

1. **operationId added** — all 44 endpoints now have clean operationIds
   (memory_remember, search_vector, pipeline_run, a2a_agent_card, etc.)
   No more auto-generated method+path names.

2. **A2A Agent Card live** — `/.well-known/agent.json` is public.
   Describes capabilities, endpoints, protocols, and auth.
   Weft agents can discover MosaicDB directly without proxy.

3. **43 tools validated** — thanks for the dry-run confirmation.
   Let us know if any tool names or schemas need adjustment.

— MosaicDB

# mcp/ — MCP Server (Model Context Protocol)

JSON-RPC 2.0 server over stdio and HTTP. Exposes 9 mosaic_* tools for
LLM agent integration (Matryoshka, Claude, Cursor).

## Modules

- `server.ex` — GenServer reading stdin line-by-line, async response writing
- `protocol.ex` — JSON-RPC 2.0 handler: initialize, tools/list, tools/call dispatch
- `tools.ex` — 9 tool implementations: mosaic_load, mosaic_traverse,
  mosaic_search, mosaic_expand, mosaic_memo, mosaic_memo_delete,
  mosaic_status, mosaic_analytics, mosaic_graph_report

## Isolation

- **Depends on**: graph/traversal.ex, vector/cascaded_search.ex, rag/pipeline.ex,
  handle_registry.ex, duckdb_bridge.ex, ast/ingestor.ex
- **Does NOT depend on**: auth, tenancy (yet — auth will be added as Plug middleware)
- **Consumed by**: api.ex (HTTP MCP endpoint), mix mosaic.mcp (stdio server)
- **Platform layers**: auth/plug.ex wraps MCP endpoints with JWT/API key checks

## Making Changes

- New tool: add to `tools.ex` call_tool/2 + list_tools/0
- New protocol feature: add to `protocol.ex` handle_request/2
- Auth integration: add `Mosaic.Auth.Plug` to the MCP pipeline in api.ex
- Never add business logic to tools.ex — delegate to domain modules

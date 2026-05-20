.PHONY: help test test-watch test-new test-isolated compile format clean

# ── Install ──────────────────────────────────────────────────────
install:
	@echo "Installing mosaic CLI..."
	@cp bin/mosaic /usr/local/bin/mosaic 2>/dev/null && echo "  → /usr/local/bin/mosaic" || \
		{ cp bin/mosaic $$HOME/.local/bin/mosaic 2>/dev/null && echo "  → $$HOME/.local/bin/mosaic"; } || \
		{ echo "  Could not install. Run: sudo cp bin/mosaic /usr/local/bin/"; exit 1; }
	@echo "  Try: mosaic help"

release:
	@echo "Building release..."
	@MIX_ENV=prod mix release mosaic 2>&1 | tail -3
	@echo "Release at: _build/prod/rel/mosaic/bin/mosaic"
	@du -sh _build/prod/rel/mosaic/

# ── Default ──────────────────────────────────────────────────────
help:
	@echo "MosaicDB — Federated Semantic Code Graph"
	@echo "========================================"
	@echo ""
	@echo "  make install         Install mosaic CLI to /usr/local/bin"
	@echo "  make release         Build self-contained release"
	@echo ""
	@echo "  make test            Run full test suite (203 tests)"
	@echo "  make compile         Compile project"
	@echo "  make format          Format all code"
	@echo "  make clean           Remove build artifacts"
	@echo ""
	@echo "  make demo            Full pipeline showcase"
	@echo "  make index           Index the MosaicDB codebase"
	@echo "  make search          Text search against indexed code"
	@echo "  make traverse        Graph traversal demos"
	@echo "  make graph-report    Graph analysis report"
	@echo ""
	@echo "  make server          Start HTTP server (port 4040)"
	@echo "  make mcp-test        Smoke-test MCP over stdio"
	@echo "  make mcp-curl        Show curl commands for MCP HTTP"
	@echo ""
	@echo "  bin/mosaic ingest <path>   CLI: index any codebase"
	@echo "  bin/mosaic search <query>  CLI: search indexed code"
	@echo "  bin/mosaic traverse <node> CLI: navigate graph"
	@echo "  bin/mosaic report          CLI: graph analysis"
	@echo ""

# ── Test ─────────────────────────────────────────────────────────
test:
	@mix test 2>&1 | tail -5

test-watch:
	@mix test.watch 2>/dev/null || fswatch lib test | while read f; do mix test; done

test-new:
	@mix test test/mosaic/graph/ test/mosaic/handle_registry_test.exs \
		test/mosaic/mcp/ test/mosaic/ast/ test/mosaic/vector/ 2>&1 | tail -3

test-isolated:
	@for f in test/mosaic/graph/*.exs test/mosaic/mcp/*.exs test/mosaic/ast/*.exs test/mosaic/vector/*.exs test/mosaic/handle_registry_test.exs; do \
		echo "=== $$f ==="; mix test $$f 2>&1 | tail -1; \
	done

compile:
	@mix compile

format:
	@mix format

clean:
	@mix clean
	@rm -rf _build deps .elixir_ls
	@echo "Cleaned. Run 'mix deps.get && mix compile' to rebuild."

# ── Full Demo ────────────────────────────────────────────────────
demo:
	@echo "============================================"
	@echo "  MosaicDB — Code Graph Demo"
	@echo "============================================"
	@echo ""
	@mix run scripts/demo.exs

# ── Index + Search + Traverse ────────────────────────────────────
index:
	@echo "Indexing MosaicDB codebase into graph..."
	@mix run scripts/index_codebase.exs

search:
	@echo "Semantic search demo..."
	@mix run scripts/search_demo.exs

traverse:
	@echo "Graph traversal demo..."
	@mix run scripts/traverse_demo.exs

graph-report:
	@echo "Graph analysis report..."
	@mix run scripts/graph_report.exs

# ── IEx + Server ─────────────────────────────────────────────────
iex:
	@iex -S mix

server:
	@echo "Starting HTTP server on port 4040..."
	@mix run --no-halt

# ── MCP ───────────────────────────────────────────────────────────
mcp-server:
	@echo "Starting MCP stdio server (press Ctrl+D to quit)..."
	@echo "Paste JSON-RPC requests, e.g.:"
	@echo '  {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
	@echo ""
	@mix mosaic.mcp

mcp-test:
	@echo "Smoke-testing MCP over stdio..."
	@printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}\n' | mix mosaic.mcp 2>/dev/null | grep '^{'

mcp-http:
	@echo "Starting HTTP server in background..."
	@mix run --no-halt &
	@sleep 3
	@echo ""
	@echo "=== GET /mcp ==="
	@curl -s http://localhost:4040/mcp | python3 -m json.tool 2>/dev/null || curl -s http://localhost:4040/mcp
	@echo ""
	@echo "=== POST /mcp tools/list ==="
	@curl -s -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \
		-d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | python3 -m json.tool 2>/dev/null
	@echo ""
	@echo "=== POST /mcp ping (SSE) ==="
	@curl -s -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \
		-H 'Accept: text/event-stream' \
		-d '{"jsonrpc":"2.0","id":2,"method":"ping","params":{}}'
	@echo ""
	@kill %1 2>/dev/null; true

mcp-curl:
	@echo "# MCP HTTP endpoint examples (server must be running: make server)"
	@echo ""
	@echo "# Server info"
	@echo "curl http://localhost:4040/mcp"
	@echo ""
	@echo "# List tools"
	@echo "curl -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \\"
	@echo "  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}'"
	@echo ""
	@echo "# Initialize"
	@echo "curl -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \\"
	@echo "  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{}}}'"
	@echo ""
	@echo "# Call tool: mosaic_status"
	@echo "curl -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \\"
	@echo "  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"mosaic_status\",\"arguments\":{}}}'"
	@echo ""
	@echo "# SSE streaming"
	@echo "curl -X POST http://localhost:4040/mcp -H 'Content-Type: application/json' \\"
	@echo "  -H 'Accept: text/event-stream' \\"
	@echo "  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{}}'"

# ── Matryoshka Integration Demo ──────────────────────────────────
integration:
	@echo "============================================"
	@echo "  Matryoshka × MosaicDB Integration"
	@echo "============================================"
	@echo ""
	@echo "Architecture:"
	@echo ""
	@echo "  Matryoshka (yogthos)          MosaicDB (this repo)"
	@echo "  ┌──────────────────┐          ┌──────────────────────┐"
	@echo "  │ LLM Reasoning    │          │ Persistent Graph DB  │"
	@echo "  │ Nucleus S-expr   │──MCP──▶  │ Recursive CTE Search │"
	@echo "  │ Lattice/miniKanren│         │ Cascaded Vec Search  │"
	@echo "  │ RLM FSM Loop     │          │ Handle Registry      │"
	@echo "  │ Tree-sitter syms │          │ Federated Shards     │"
	@echo "  └──────────────────┘          └──────────────────────┘"
	@echo ""
	@echo "Matryoshka calls mosaic_* tools via MCP to persist"
	@echo "code graph data, traverse relationships, and search"
	@echo "semantically — all backed by SQLite shards."
	@echo ""
	@echo "Run 'make mcp-curl' to see the MCP HTTP commands"
	@echo "Matryoshka would invoke."
	@echo ""
	@echo "Run 'make demo' for the full pipeline."

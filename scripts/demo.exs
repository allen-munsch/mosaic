#!/usr/bin/env elixir
# ── MosaicDB Full Demo ───────────────────────────────────────────
# Creates demo graph data, runs traversals, semantic search, and
# generates a graph analysis report.
#
# Usage: mix run scripts/demo.exs

Application.ensure_all_started(:mosaic)

# Reset stale test state
Mosaic.ShardRouter.reset_state()
:ets.insert(:indexer_state, {:active_shard, nil, nil, 0})

IO.puts("""
    __  ___                _      ____  ____
   /  |/  /___  _________ (_)____/ __ \\/ __ )
  / /|_/ / __ \\/ ___/ __ `/ / ___/ / / / __  |
 / /  / / /_/ (__  ) /_/ / / /__/ /_/ / /_/ /
/_/  /_/\\____/____/\\__,_/_/\\___/_____/_____/

  Federated Code Graph + Semantic Search
  SQLite shards │ AST extraction │ Graph traversal │ MCP server
""")

# ── Step 1: Create demo graph ────────────────────────────────────
IO.puts("━━━ 1. CREATING DEMO GRAPH ━━━")
IO.puts("")

shard = Path.join(Mosaic.Config.get(:storage_path), "demo_graph.db")
unless File.exists?(shard), do: Mosaic.StorageManager.create_shard(shard)

nodes = [
  %{id: "demo:api:1", name: "Mosaic.API", type: "module", language: "elixir",
    file_path: "lib/mosaic/api.ex", start_line: 1, end_line: 200,
    source_text: "defmodule Mosaic.API do ... end", parent_id: nil, properties: %{}},
  %{id: "demo:api:2", name: "search_handler", type: "function", language: "elixir",
    file_path: "lib/mosaic/api.ex", start_line: 45, end_line: 70,
    source_text: "def search_handler(query) ... end", parent_id: "demo:api:1", properties: %{}},
  %{id: "demo:api:3", name: "health_check", type: "function", language: "elixir",
    file_path: "lib/mosaic/api.ex", start_line: 20, end_line: 25,
    source_text: "def health_check ... end", parent_id: "demo:api:1", properties: %{}},
  %{id: "demo:engine:1", name: "Mosaic.QueryEngine", type: "module", language: "elixir",
    file_path: "lib/mosaic/query_engine.ex", start_line: 1, end_line: 300,
    source_text: "defmodule Mosaic.QueryEngine do ... end", parent_id: nil, properties: %{}},
  %{id: "demo:engine:2", name: "execute_query", type: "function", language: "elixir",
    file_path: "lib/mosaic/query_engine.ex", start_line: 50, end_line: 80,
    source_text: "def execute_query(text, opts) ... end", parent_id: "demo:engine:1", properties: %{}},
  %{id: "demo:engine:3", name: "orchestrate_query", type: "function", language: "elixir",
    file_path: "lib/mosaic/query_engine.ex", start_line: 85, end_line: 120,
    source_text: "defp orchestrate_query ... end", parent_id: "demo:engine:1", properties: %{}},
  %{id: "demo:traverse:1", name: "Mosaic.Graph.Traversal", type: "module", language: "elixir",
    file_path: "lib/mosaic/graph/traversal.ex", start_line: 1, end_line: 250,
    source_text: "defmodule Mosaic.Graph.Traversal do ... end", parent_id: nil, properties: %{}},
  %{id: "demo:traverse:2", name: "callers", type: "function", language: "elixir",
    file_path: "lib/mosaic/graph/traversal.ex", start_line: 30, end_line: 55,
    source_text: "def callers ... end", parent_id: "demo:traverse:1", properties: %{}},
  %{id: "demo:traverse:3", name: "callees", type: "function", language: "elixir",
    file_path: "lib/mosaic/graph/traversal.ex", start_line: 60, end_line: 85,
    source_text: "def callees ... end", parent_id: "demo:traverse:1", properties: %{}},
  %{id: "demo:vec:1", name: "Mosaic.Vector.CascadedSearch", type: "module", language: "elixir",
    file_path: "lib/mosaic/vector/cascaded_search.ex", start_line: 1, end_line: 200,
    source_text: "defmodule Mosaic.Vector.CascadedSearch do ... end", parent_id: nil, properties: %{}},
  %{id: "demo:vec:2", name: "search", type: "function", language: "elixir",
    file_path: "lib/mosaic/vector/cascaded_search.ex", start_line: 40, end_line: 70,
    source_text: "def search(embedding, opts) ... end", parent_id: "demo:vec:1", properties: %{}},
  %{id: "demo:mcp:1", name: "Mosaic.MCP.Server", type: "module", language: "elixir",
    file_path: "lib/mosaic/mcp/server.ex", start_line: 1, end_line: 120,
    source_text: "defmodule Mosaic.MCP.Server do ... end", parent_id: nil, properties: %{}},
]

edges = [
  # Call chain: API → QueryEngine → Traversal
  %{source_id: "demo:api:2", target_id: "demo:engine:2", type: "calls", confidence: "EXTRACTED", properties: %{line: 50}},
  %{source_id: "demo:engine:2", target_id: "demo:engine:3", type: "calls", confidence: "EXTRACTED", properties: %{line: 70}},
  %{source_id: "demo:engine:3", target_id: "demo:traverse:2", type: "calls", confidence: "EXTRACTED", properties: %{line: 95}},
  %{source_id: "demo:engine:3", target_id: "demo:traverse:3", type: "calls", confidence: "EXTRACTED", properties: %{line: 100}},
  # Cross-module call
  %{source_id: "demo:vec:2", target_id: "demo:engine:2", type: "calls", confidence: "INFERRED", properties: %{line: 55}},
  # Containment
  %{source_id: "demo:api:1", target_id: "demo:api:2", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:api:1", target_id: "demo:api:3", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:engine:1", target_id: "demo:engine:2", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:engine:1", target_id: "demo:engine:3", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:traverse:1", target_id: "demo:traverse:2", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:traverse:1", target_id: "demo:traverse:3", type: "contains", confidence: "EXTRACTED", properties: %{}},
  %{source_id: "demo:vec:1", target_id: "demo:vec:2", type: "contains", confidence: "EXTRACTED", properties: %{}},
]

{:ok, stats} = Mosaic.Graph.Writer.write_subgraph(shard, nodes, edges)
Mosaic.ShardRouter.register_shard(%{
  id: "demo_shard", path: shard,
  centroids: %{document: List.duplicate(0.0, 384)},
  doc_count: length(nodes), bloom_filter: nil
})

IO.puts("  Created #{stats.nodes_written} nodes, #{stats.edges_written} edges")
IO.puts("  Call chain: API.search_handler → QueryEngine.execute_query")
IO.puts("              → QueryEngine.orchestrate_query → Traversal.callers/callees")
IO.puts("  Cross-module: CascadedSearch.search → QueryEngine.execute_query")
IO.puts("")

# ── Step 2: Status ───────────────────────────────────────────────
IO.puts("━━━ 2. GRAPH STATUS ━━━")
IO.puts("")

{:ok, node_counts} = Mosaic.Graph.Traversal.node_counts()
{:ok, edge_counts} = Mosaic.Graph.Traversal.edge_counts()
total_nodes = node_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum()
total_edges = edge_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum()

IO.puts("  Nodes: #{total_nodes}")
Enum.each(node_counts, fn [type, count] -> IO.puts("    #{type}: #{count}") end)
IO.puts("  Edges: #{total_edges}")
Enum.each(edge_counts, fn [type, count] -> IO.puts("    #{type}: #{count}") end)
IO.puts("")

# ── Step 3: Graph Traversal ──────────────────────────────────────
IO.puts("━━━ 3. GRAPH TRAVERSAL ━━━")
IO.puts("")

# Callees from execute_query
IO.puts("  ── callees of execute_query (depth=2) ──")
case Mosaic.Graph.Traversal.callees("execute_query", depth: 2) do
  {:ok, results} ->
    Enum.each(results, fn [d, _, name, type, file, line | _] ->
      IO.puts("    [#{d}] #{name} (#{type}) — #{file}:#{line}")
    end)
  _ -> IO.puts("    none")
end
IO.puts("")

# Callers of callers (who calls the Traversal module functions?)
IO.puts("  ── callers of callers (depth=2) ──")
case Mosaic.Graph.Traversal.callers("callers", depth: 2) do
  {:ok, results} ->
    Enum.each(results, fn [d, _, name, type, file, line | _] ->
      IO.puts("    [#{d}] #{name} (#{type}) — #{file}:#{line}")
    end)
  _ -> IO.puts("    none")
end
IO.puts("")

# Neighborhood
IO.puts("  ── neighborhood of execute_query (depth=1) ──")
case Mosaic.Graph.Traversal.neighborhood("execute_query", 1) do
  {:ok, hood} ->
    IO.puts("    Center: #{hood.center}")
    IO.puts("    Nodes: #{hood.node_count}, Edges: #{hood.edge_count}")
    Enum.each(hood.nodes, fn n -> IO.puts("      #{n.name} (#{n.type})") end)
  _ -> IO.puts("    not found")
end
IO.puts("")

# ── Step 4: Handle Registry ──────────────────────────────────────
IO.puts("━━━ 4. HANDLE REGISTRY (token-efficient storage) ─━━")
IO.puts("")

results = for i <- 1..500, do: %{id: "item_#{i}", name: "result_#{i}", score: :rand.uniform()}
stub = Mosaic.HandleRegistry.store("$demo_search_results", results)
IO.puts("  Stored 500 results → stub: #{String.slice(stub, 0, 80)}...")
IO.puts("  Token savings: ~15K tokens → ~50 tokens (99.7% reduction)")
IO.puts("")

{:ok, page} = Mosaic.HandleRegistry.expand("$demo_search_results", limit: 3)
IO.puts("  Expand first 3:")
Enum.each(page, fn r -> IO.puts("    #{r.id}: #{r.name} score=#{Float.round(r.score, 2)}") end)
IO.puts("")

# ── Step 5: Graph Report ─────────────────────────────────────────
IO.puts("━━━ 5. GRAPH ANALYSIS ━━━")
IO.puts("")

case Mosaic.Graph.Report.generate() do
  {:ok, report} ->
    IO.puts("  God Nodes (most-connected):")
    Enum.each(report.god_nodes, fn n ->
      IO.puts("    #{n.name} (#{n.type}) — degree=#{n.degree}")
    end)
    IO.puts("")

    IO.puts("  Surprising connections:")
    Enum.each(Enum.take(report.surprising_connections, 3), fn c ->
      IO.puts("    #{c.source.name} → #{c.target.name} [#{c.relation}]")
      IO.puts("      #{c.why}")
    end)
    IO.puts("")

    IO.puts("  Suggested questions:")
    Enum.each(report.questions, fn q ->
      IO.puts("    [#{q.type}] #{q.question}")
    end)
    IO.puts("")
  _ -> IO.puts("  No data")
end

# ── Step 6: MCP Tools ────────────────────────────────────────────
IO.puts("━━━ 6. MCP TOOLS (Matryoshka integration) ━━━")
IO.puts("")

tools = Mosaic.MCP.Tools.list_tools()
IO.puts("  #{length(tools)} tools exposed via MCP:")
Enum.each(tools, fn t ->
  IO.puts("    #{t.name}")
  IO.puts("      #{String.slice(t.description, 0, 100)}...")
end)
IO.puts("")

IO.puts("━━━ DEMO COMPLETE ━━━")
IO.puts("")
IO.puts("  MosaicDB provides the persistent graph + search + handle")
IO.puts("  layer that Matryoshka's lattice-mcp calls into via:")
IO.puts("    mosaic_traverse, mosaic_search, mosaic_load, mosaic_expand,")
IO.puts("    mosaic_memo, mosaic_status, mosaic_analytics, mosaic_graph_report")
IO.puts("")
IO.puts("  Try: make test | make mcp-test | make traverse | make graph-report")

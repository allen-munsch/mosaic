#!/usr/bin/env elixir
# ── Graph Traversal Demo ────────────────────────────────────────
Application.ensure_all_started(:mosaic)
Mosaic.ShardAutoDiscover.discover()

alias Mosaic.Graph.Traversal

IO.puts("Graph Traversal Demo")
IO.puts("===================")
IO.puts("")

# Find some interesting nodes
{:ok, functions} = Traversal.node_counts()
fn_count = functions |> Enum.find_value(fn [t, c] -> t == "function" && c end) || 0
mod_count = functions |> Enum.find_value(fn [t, c] -> t == "module" && c end) || 0

IO.puts("Indexed: #{fn_count} functions, #{mod_count} modules")
IO.puts("")

# Pick a function node to explore
fn_rows = Mosaic.FederatedQuery.execute("SELECT name FROM nodes WHERE type = 'function' LIMIT 1", [])
fn_name = case fn_rows do
  [[name | _] | _] -> name
  _ -> nil
end

if is_nil(fn_name) do
  IO.puts("No functions indexed. Run 'make index' first.")
  System.halt(0)
end

IO.puts("Exploring: #{fn_name}")
IO.puts("")

# Callers
IO.puts("── callers (depth=2) ──")
case Traversal.callers(fn_name, depth: 2) do
  {:ok, callers} when callers != [] ->
    Enum.each(callers, fn [d, _, name, type, file, line | _] ->
      IO.puts("  [#{d}] #{name} (#{type}) — #{file}:#{line}")
    end)
  _ -> IO.puts("  none")
end
IO.puts("")

# Callees
IO.puts("── callees (depth=2) ──")
case Traversal.callees(fn_name, depth: 2) do
  {:ok, callees} when callees != [] ->
    Enum.each(callees, fn [d, _, name, type, file, line | _] ->
      IO.puts("  [#{d}] #{name} (#{type}) — #{file}:#{line}")
    end)
  _ -> IO.puts("  none")
end
IO.puts("")

# Neighborhood
IO.puts("── neighborhood (depth=1) ──")
case Traversal.neighborhood(fn_name, 1) do
  {:ok, hood} ->
    IO.puts("  Center: #{hood.center}")
    IO.puts("  Nodes in radius: #{hood.node_count}")
    IO.puts("  Edges in radius: #{hood.edge_count}")
    IO.puts("  Connected nodes:")
    Enum.each(Enum.take(hood.nodes, 10), fn n ->
      IO.puts("    #{n.name} (#{n.type}) — #{n.file}")
    end)
  _ -> IO.puts("  not found")
end
IO.puts("")

# God nodes
IO.puts("── god nodes (top 5) ──")
case Traversal.god_nodes(5) do
  {:ok, nodes} ->
    Enum.each(nodes, fn n ->
      IO.puts("  #{n.name} (#{n.type}) — degree=#{n.degree}")
    end)
  _ -> IO.puts("  none")
end

#!/usr/bin/env elixir
# ── Graph Analysis Report ──────────────────────────────────────
Application.ensure_all_started(:mosaic)

IO.puts("MosaicDB Graph Analysis Report")
IO.puts("==============================")
IO.puts("")

case Mosaic.Graph.Report.generate() do
  {:ok, report} ->
    s = report.summary
    IO.puts("Summary")
    IO.puts("───────")
    IO.puts("  Total nodes:  #{s.total_nodes}")
    IO.puts("  Total edges:  #{s.total_edges}")
    IO.puts("  Communities:  #{s.community_count}")
    IO.puts("")
    IO.puts("  Node types:")
    Enum.each(s.node_types, fn t -> IO.puts("    #{t.type}: #{t.count}") end)
    IO.puts("")
    IO.puts("  Edge types:")
    Enum.each(s.edge_types, fn t -> IO.puts("    #{t.type}: #{t.count}") end)
    IO.puts("")

    unless Enum.empty?(report.god_nodes) do
      IO.puts("God Nodes (connection hubs)")
      IO.puts("───────────────────────────")
      Enum.each(report.god_nodes, fn n ->
        IO.puts("  #{n.name} (#{n.type}) — degree=#{n.degree}")
        IO.puts("    #{n.file}")
      end)
      IO.puts("")
    end

    unless Enum.empty?(report.bridge_nodes) do
      IO.puts("Bridge Nodes (cross-module connectors)")
      IO.puts("──────────────────────────────────────")
      Enum.each(report.bridge_nodes, fn n ->
        IO.puts("  #{n.name} (#{n.type}) — reach=#{n.community_reach}")
      end)
      IO.puts("")
    end

    unless Enum.empty?(report.communities) do
      IO.puts("Communities")
      IO.puts("───────────")
      Enum.each(Enum.take(report.communities, 8), fn c ->
        IO.puts("  #{c.community}: #{c.node_count} nodes, cohesion=#{c.cohesion}")
      end)
      IO.puts("")
    end

    unless Enum.empty?(report.surprising_connections) do
      IO.puts("Surprising Connections")
      IO.puts("─────────────────────")
      Enum.each(Enum.take(report.surprising_connections, 5), fn c ->
        IO.puts("  #{c.source.name} → #{c.target.name} [#{c.relation}]")
        IO.puts("    #{c.why}")
      end)
      IO.puts("")
    end

    unless Enum.empty?(report.questions) do
      IO.puts("Suggested Questions")
      IO.puts("───────────────────")
      Enum.each(report.questions, fn q ->
        IO.puts("  [#{q.type}] #{q.question}")
        IO.puts("    #{q.why}")
      end)
      IO.puts("")
    end

  {:error, reason} ->
    IO.puts("No indexed data yet. Run 'make index' first.")
    IO.puts("Error: #{inspect(reason)}")
end

#!/usr/bin/env elixir
# ── Index the MosaicDB Codebase ─────────────────────────────────
Application.ensure_all_started(:mosaic)

alias Mosaic.AST.BuiltinParser
alias Mosaic.Graph.Writer

files = Path.wildcard("lib/mosaic/**/*.ex")
IO.puts("Indexing #{length(files)} files (built-in parser, no external deps)...")

shard_path = Path.join(Mosaic.Config.get(:storage_path), "mosaic_codebase.db")
unless File.exists?(shard_path), do: Mosaic.StorageManager.create_shard(shard_path)

started = System.monotonic_time(:millisecond)
{:ok, agent} = Agent.start_link(fn -> %{nodes: 0, edges: 0, errors: 0} end)

Enum.each(files, fn file ->
  case File.read(file) do
    {:ok, source} ->
      ext = Path.extname(file)
      result = cond do
        ext in [".ex", ".exs"] -> BuiltinParser.extract_elixir(source, file)
        ext in [".py", ".pyi"] -> BuiltinParser.extract_python(source, file)
        true -> {[], []}
      end

      {nodes, edges} = result

      unless Enum.empty?(nodes) do
        case Writer.write_subgraph(shard_path, nodes, edges) do
          {:ok, stats} ->
            Agent.update(agent, fn s ->
              %{s | nodes: s.nodes + stats.nodes_written, edges: s.edges + stats.edges_written}
            end)
            IO.write(".")
          {:error, _} ->
            Agent.update(agent, fn s -> %{s | errors: s.errors + 1} end)
            IO.write("x")
        end
      end

    {:error, _} ->
      Agent.update(agent, fn s -> %{s | errors: s.errors + 1} end)
      IO.write("x")
  end
end)

counts = Agent.get(agent, & &1)
Agent.stop(agent)

elapsed = System.monotonic_time(:millisecond) - started
IO.puts("")
IO.puts("Done in #{elapsed}ms")
IO.puts("  Files: #{length(files)}")
IO.puts("  Nodes: #{counts.nodes}")
IO.puts("  Edges: #{counts.edges}")
IO.puts("  Errors: #{counts.errors}")
IO.puts("  Shard: #{shard_path}")

# Register in shard router
Mosaic.ShardRouter.reset_state()
Mosaic.ShardRouter.register_shard(%{
  id: "codebase_shard",
  path: shard_path,
  centroids: %{document: List.duplicate(0.0, 384)},
  doc_count: counts.nodes,
  bloom_filter: nil
})

IO.puts("  Registered in shard router — ready for traverse/search")

#!/usr/bin/env elixir
# ── Index the MosaicDB Codebase ─────────────────────────────────
Application.ensure_all_started(:mosaic)

alias Mosaic.AST.{Parser, SymbolExtractor, RelationshipExtractor}
alias Mosaic.Graph.Writer

files = Path.wildcard("lib/mosaic/**/*.ex")
IO.puts("Indexing #{length(files)} files...")

shard_path = Path.join(Mosaic.Config.get(:storage_path), "mosaic_codebase.db")
unless File.exists?(shard_path), do: Mosaic.StorageManager.create_shard(shard_path)

started = System.monotonic_time(:millisecond)
total_nodes = 0
total_edges = 0
errors = 0

Enum.each(files, fn file ->
  lang = Parser.detect_language(file)

  if lang do
    case Parser.parse_file(file, language: lang) do
      {:ok, ast} ->
        nodes = SymbolExtractor.extract(ast, file, lang)

        unless Enum.empty?(nodes) do
          edges = RelationshipExtractor.extract(ast, nodes, file, lang)
          {:ok, stats} = Writer.write_subgraph(shard_path, nodes, edges)

          total_nodes = total_nodes + stats.nodes_written
          total_edges = total_edges + stats.edges_written
          IO.write(".")
        end

      {:error, _} ->
        errors = errors + 1
        IO.write("x")
    end
  end
end)

elapsed = System.monotonic_time(:millisecond) - started
IO.puts("")
IO.puts("Done in #{elapsed}ms")
IO.puts("  Files: #{length(files)}")
IO.puts("  Nodes: #{total_nodes}")
IO.puts("  Edges: #{total_edges}")
IO.puts("  Errors: #{errors}")
IO.puts("  Shard: #{shard_path}")

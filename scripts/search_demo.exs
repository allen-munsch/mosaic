#!/usr/bin/env elixir
# ── Semantic Search Demo ────────────────────────────────────────
Application.ensure_all_started(:mosaic)
Mosaic.ShardAutoDiscover.discover()

alias Mosaic.Vector.CascadedSearch

queries = [
  "error handling in GenServer callbacks",
  "vector similarity search with SQLite",
  "connection pooling for database access",
  "graph traversal with recursive CTEs",
  "token-efficient handle storage"
]

IO.puts("Semantic Search Demo")
IO.puts("====================")
IO.puts("")

Enum.each(queries, fn query ->
  IO.puts("Query: \"#{query}\"")
  IO.puts(String.duplicate("-", 60))

  results = CascadedSearch.search_text(query, limit: 5, skip_levels: true)

  if results == [] do
    IO.puts("  (no indexed code — run 'make index' first)")
  else
    Enum.each(results, fn r ->
      IO.puts("  [#{r.type}] #{r.name}")
      IO.puts("    #{r.file_path}:#{r.start_line}  sim=#{r.similarity}")
    end)
  end

  IO.puts("")
end)

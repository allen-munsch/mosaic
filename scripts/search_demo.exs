#!/usr/bin/env elixir
# ── Semantic Search Demo ────────────────────────────────────────
Application.ensure_all_started(:mosaic)
Mosaic.ShardAutoDiscover.discover()

IO.puts("Semantic Search Demo")
IO.puts("====================")
IO.puts("")

queries = [
  "error handling in GenServer callbacks",
  "vector similarity search with SQLite",
  "connection pooling for database access",
  "graph traversal with recursive CTEs",
  "token-efficient handle storage"
]

Enum.each(queries, fn query ->
  IO.puts("Query: \"#{query}\"")
  IO.puts(String.duplicate("-", 60))

  # Text-based search: match any query word in name
  like_clauses = Enum.map_join(String.split(query, " "), " OR ", fn _ -> "name LIKE ?" end)
  params = String.split(query, " ") |> Enum.map(&"%#{&1}%")
  sql = "SELECT name, type, file_path, start_line FROM nodes WHERE #{like_clauses} LIMIT 5"

  try do
    results = Mosaic.FederatedQuery.execute(sql, params)

    if results != [] do
      IO.puts("  Text matches (no embeddings needed):")
      Enum.each(Enum.take(results, 5), fn row ->
        case row do
          [name, type, file, line] ->
            IO.puts("    [#{type}] #{name} — #{file}:#{line}")
          _ -> :ok
        end
      end)
    else
      IO.puts("  (no matches — try 'make index' first)")
    end
  rescue
    _ -> IO.puts("  (error querying — is the graph indexed?)")
  end

  IO.puts("")
end)

IO.puts("Note: Vector search requires Bumblebee/EXLA embeddings.")
IO.puts("Text search works immediately after 'make index'.")

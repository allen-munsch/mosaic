defmodule Mosaic.DuckDBBridge do
  @moduledoc "DuckDB for analytical queries across SQLite shards"

  def query(sql, params \\ []) do
    shards = Mosaic.ShardRouter.list_all_shards()

    # Build DuckDB query that attaches all relevant shards
    duckdb_sql = """
    #{attach_statements(shards)}

    #{rewrite_query(sql, shards)}
    """

    execute_duckdb(duckdb_sql, params)
  end

  defp attach_statements(shards) do
    shards
    |> Enum.with_index()
    |> Enum.map(fn {shard, i} ->
      "ATTACH '#{shard.path}' AS shard_#{i} (TYPE sqlite);"
    end)
    |> Enum.join("\n")
  end

  defp rewrite_query(sql, shards) do
    # Rewrite "FROM documents" to UNION ALL across shards
    # DuckDB optimizer handles the rest
    shard_queries = shards
    |> Enum.with_index()
    |> Enum.map(fn {_, i} ->
      String.replace(sql, "FROM documents", "FROM shard_#{i}.documents")
    end)
    |> Enum.join("\nUNION ALL\n")

    "SELECT * FROM (#{shard_queries})"
  end
end

defmodule Mosaic.HybridQuery do
  def search(query_text, opts) do
    embedding = Mosaic.EmbeddingService.encode(query_text)
    sql_filter = opts[:where]

    case classify_query(sql_filter) do
      :simple ->
        # Push everything to SQLite
        sqlite_vector_search(embedding, sql_filter, opts)

      :complex ->
        # Two-phase: vector search in SQLite, then analytics in DuckDB
        candidate_ids = sqlite_vector_search(embedding, nil, limit: opts[:limit] * 10)

        duckdb_sql = """
        SELECT * FROM documents
        WHERE id IN (#{format_ids(candidate_ids)})
        AND #{sql_filter}
        #{opts[:group_by]}
        #{opts[:order_by]}
        LIMIT #{opts[:limit]}
        """

        Mosaic.DuckDBBridge.query(duckdb_sql)
    end
  end

  defp classify_query(nil), do: :simple
  defp classify_query(sql) do
    if Regex.match?(~r/(GROUP BY|HAVING|JOIN|WINDOW|WITH)/i, sql) do
      :complex
    else
      :simple
    end
  end
end

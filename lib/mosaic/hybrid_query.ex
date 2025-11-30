defmodule Mosaic.HybridQuery do
  require Logger



  def search(query_text, opts \\ []) do
    embedding = Mosaic.EmbeddingService.encode(query_text)
    sql_filter = Keyword.get(opts, :where)
    limit = Keyword.get(opts, :limit, 20)
    min_similarity = Keyword.get(opts, :min_similarity, 0.0)

    shards = select_shards(embedding, opts)

    candidates = shards
    |> Task.async_stream(&search_shard(&1, embedding, sql_filter, limit * 3), timeout: 5_000, on_timeout: :kill_task, ordered: false)
    |> Enum.flat_map(fn
      {:ok, {:ok, results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end)

    candidates
    |> Enum.filter(&(&1.similarity >= min_similarity))
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
  end

  defp select_shards(embedding, opts) do
    shard_limit = Keyword.get(opts, :shard_limit, 10)
    case Mosaic.ShardRouter.find_similar_shards(embedding, shard_limit, opts) do
      {:ok, shards} -> shards
      {:error, _} -> []
    end
  end

  defp search_shard(shard, embedding, sql_filter, limit) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        results = do_vector_search(conn, embedding, sql_filter, limit)
        Mosaic.ConnectionPool.checkin(shard.path, conn)
        {:ok, Enum.map(results, &Map.put(&1, :shard_id, shard.id))}
      {:error, reason} ->
        Logger.warning("Shard #{shard.id} unavailable: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_vector_search(conn, embedding, sql_filter, limit) do
    vector_json = Jason.encode!(embedding)
    where_clause = if sql_filter, do: "AND #{sql_filter}", else: ""

    sql = """
    SELECT d.id, d.text, d.metadata, d.created_at, d.pagerank, vec_distance_cosine(d.embedding, ?) as distance
    FROM documents d
    WHERE 1=1 #{where_clause}
    ORDER BY distance ASC
    LIMIT ?
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [vector_json, limit])
    rows = fetch_all_rows(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)

    Enum.map(rows, fn [id, text, metadata, created_at, pagerank, distance] ->
      %{
        id: id,
        text: text,
        metadata: safe_decode(metadata),
        created_at: parse_datetime(created_at),
        pagerank: pagerank || 0.0,
        similarity: distance_to_similarity(distance)
      }
    end)
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, reason} ->
        Logger.warning("SQLite error: #{inspect(reason)}")
        Enum.reverse(acc)
    end
  end

  defp distance_to_similarity(nil), do: 0.0
  defp distance_to_similarity(d) when is_number(d), do: 1.0 / (1.0 + d)

  defp safe_decode(nil), do: %{}
  defp safe_decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

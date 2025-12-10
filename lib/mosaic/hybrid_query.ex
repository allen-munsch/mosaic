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

  def select_shards(query_embedding, opts \\ []) do
    shard_limit = Keyword.get(opts, :shard_limit, 5)
    
    case Mosaic.ShardRouter.find_similar_shards_sync(query_embedding, shard_limit, opts) do
      shards when is_list(shards) ->
        Enum.map(shards, fn shard ->
          %{id: shard.id, path: shard.path, similarity: shard.similarity}
        end)
      {:ok, shards} when is_list(shards) ->
        Enum.map(shards, fn shard ->
          %{id: shard.id, path: shard.path, similarity: shard.similarity}
        end)
      {:error, reason} ->
        Logger.error("Failed to select shards: #{inspect(reason)}")
        []
      other ->
        Logger.warning("Unexpected shard response: #{inspect(other)}")
        []
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
    SELECT c.id, c.doc_id, c.text, d.metadata, d.created_at, c.pagerank, vec_distance_cosine(vc.embedding, ?) as distance
    FROM chunks c
    JOIN vec_chunks vc ON c.id = vc.id
    JOIN documents d ON c.doc_id = d.id
    WHERE c.level = 'paragraph' #{where_clause}
    ORDER BY distance ASC
    LIMIT ?
  """
  case Mosaic.DB.query(conn, sql, [vector_json, limit]) do
    {:ok, rows} ->
      Enum.map(rows, fn [id, doc_id, text, metadata, created_at, pagerank, distance] ->
        %{id: id, doc_id: doc_id, text: text, metadata: safe_decode(metadata), created_at: parse_datetime(created_at), pagerank: pagerank || 0.0, similarity: distance_to_similarity(distance)}
      end)
    {:error, err} ->
      Logger.warning("Vector search error: #{inspect(err)}")
      []
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

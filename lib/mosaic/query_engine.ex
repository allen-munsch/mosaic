defmodule Mosaic.QueryEngine do
  use GenServer
  require Logger
  @behaviour Mosaic.QueryEngine.Behaviour

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    redis_url = Mosaic.Config.get(:redis_url)
    {:ok, redix_conn} = Redix.start_link(redis_url)
    {:ok, %{redix_conn: redix_conn}}
  end

  def search(query_text, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query_text, opts}, Mosaic.Config.get(:query_timeout))
  end

  def handle_call({:search, query_text, opts}, _from, state) do
    redix_conn = state.redix_conn
    query_cache_ttl = Mosaic.Config.get(:query_cache_ttl_seconds)
    default_result_limit = Mosaic.Config.get(:default_result_limit)
    limit = Keyword.get(opts, :limit, default_result_limit)
    cache_key = generate_cache_key(query_text, opts)

    case Redix.command(redix_conn, ["GET", cache_key]) do
      {:ok, cached_results_json} when is_binary(cached_results_json) ->
        Logger.info("Query cache hit for: #{query_text}")
        {:reply, {:ok, Jason.decode!(cached_results_json)}, state}
      _ ->
        Logger.info("Query cache miss for: #{query_text}")
        query_embedding = Mosaic.EmbeddingService.encode(query_text)

        # FIX: Unwrap {:ok, shards} tuple from find_similar_shards
        candidate_shards = case Mosaic.ShardRouter.find_similar_shards(query_embedding, Mosaic.Config.get(:default_shard_limit), opts) do
          {:ok, shards} -> shards
          shards when is_list(shards) -> shards
        end

        results = candidate_shards
        |> Task.async_stream(fn shard ->
          do_shard_search(shard, query_embedding, limit)
        end, ordered: false, timeout: Mosaic.Config.get(:query_timeout))
        |> Enum.flat_map(fn
          {:ok, {:ok, shard_results}} -> shard_results
          {:ok, shard_results} when is_list(shard_results) -> shard_results
          _ -> []
        end)

        final_results = results
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

        Redix.command(redix_conn, ["SETEX", cache_key, query_cache_ttl, Jason.encode!(final_results)])
        {:reply, {:ok, final_results}, state}
    end
  end

  defp do_shard_search(shard, query_embedding, limit) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        vector_json = Jason.encode!(query_embedding)
        sql = "SELECT rowid, distance FROM vss_vectors WHERE vss_search(vec, ?) LIMIT ?"
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
        :ok = Exqlite.Sqlite3.bind(stmt, [vector_json, limit])
        vss_rows = fetch_all_rows(conn, stmt, [])
        Exqlite.Sqlite3.release(conn, stmt)

        results = Enum.map(vss_rows, fn [rowid, distance] ->
          {:ok, doc_stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT id, text, metadata FROM documents WHERE rowid = ?")
          :ok = Exqlite.Sqlite3.bind(doc_stmt, [rowid])
          doc = case Exqlite.Sqlite3.step(conn, doc_stmt) do
            {:row, [id, text, metadata]} -> %{id: id, text: text, metadata: metadata}
            :done -> nil
          end
          Exqlite.Sqlite3.release(conn, doc_stmt)
          if doc do
            similarity = if is_number(distance), do: 1.0 / (1.0 + distance), else: 0.0
            Map.merge(doc, %{similarity: similarity, shard_id: shard.id})
          end
        end)
        |> Enum.reject(&is_nil/1)

        Mosaic.ConnectionPool.checkin(shard.path, conn)
        {:ok, results}
      error ->
        Logger.error("Failed to checkout connection for shard #{shard.id}: #{inspect(error)}")
        {:error, []}
    end
  end

  def execute_federated(sql, params \\ [], opts \\ []) do
    shards = case Keyword.get(opts, :shards) do
      nil ->
        {:ok, all} = Mosaic.ShardRouter.find_similar_shards(List.duplicate(0.0, 384), 1000, min_similarity: 0.0)
        all
      ids ->
        # fetch specific shards by id
        ids
    end

    shards
    |> Task.async_stream(fn shard ->
      {:ok, conn} = Mosaic.ConnectionPool.checkout(shard.path)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      rows = fetch_all_rows(conn, stmt, [])
      Exqlite.Sqlite3.release(conn, stmt)
      Mosaic.ConnectionPool.checkin(shard.path, conn)
      {shard.id, rows}
    end, timeout: 30_000)
    |> Enum.flat_map(fn {:ok, {_shard_id, rows}} -> rows; _ -> [] end)
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, _} = err -> err
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp generate_cache_key(query_text, opts) do
    opts_hash = :erlang.phash2(Enum.sort(opts))
    "query:#{query_text}:#{opts_hash}"
  end
end

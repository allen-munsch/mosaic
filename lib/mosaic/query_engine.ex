defmodule Mosaic.QueryEngine do
  use GenServer
  require Logger
  @behaviour Mosaic.QueryEngine.Behaviour

  alias Mosaic.Ranking.Ranker

  defstruct [
    :cache,           # Cache implementation module
    :ranker,          # Ranker configuration
    :cache_ttl
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    cache_impl = Keyword.get(opts, :cache, Mosaic.Cache.ETS)
    cache_ttl = Keyword.get(opts, :cache_ttl, 300)
    ranker = Keyword.get(opts, :ranker, Ranker.new())

    state = %__MODULE__{ 
      cache: cache_impl,
      ranker: ranker,
      cache_ttl: cache_ttl
    }

    {:ok, state}
  end

  def search(query_text, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query_text, opts}, 30_000)
  end

  @doc "Search with custom ranker configuration"
  def search_with_ranker(query_text, ranker_opts, search_opts \\ []) do
    GenServer.call(__MODULE__, {:search_with_ranker, query_text, ranker_opts, search_opts}, 30_000)
  end

  def handle_call({:search, query_text, opts}, _from, state) do
    result = do_search(query_text, opts, state.ranker, state)
    {:reply, result, state}
  end

  def handle_call({:search_with_ranker, query_text, ranker_opts, search_opts}, _from, state) do
    custom_ranker = Ranker.new(ranker_opts)
    result = do_search(query_text, search_opts, custom_ranker, state)
    {:reply, result, state}
  end

  defp do_search(query_text, opts, ranker, state) do
    limit = Keyword.get(opts, :limit, 20)
    skip_cache = Keyword.get(opts, :skip_cache, false)
    cache_key = build_cache_key(query_text, opts, ranker)

    # Check cache
    unless skip_cache do
      case state.cache.get(cache_key) do
        {:ok, cached} ->
          Logger.debug("Cache hit for query: #{query_text}")
          {:ok, cached}

        :miss ->
          execute_and_cache(query_text, opts, ranker, cache_key, limit, state)
      end
    else
      execute_search(query_text, opts, ranker, limit)
    end
  end

  defp execute_and_cache(query_text, opts, ranker, cache_key, limit, state) do
    case execute_search(query_text, opts, ranker, limit) do
      {:ok, results} = success ->
        state.cache.put(cache_key, results, state.cache_ttl)
        success

      error ->
        error
    end
  end

  defp execute_search(query_text, opts, ranker, limit) do
    # Generate embedding
    query_embedding = Mosaic.EmbeddingService.encode(query_text)
    query_terms = extract_terms(query_text)

    # Build ranking context
    context = %{
      query_text: query_text,
      query_terms: query_terms,
      query_embedding: query_embedding
    }

    # Find candidate shards
    shard_limit = Keyword.get(opts, :shard_limit, Mosaic.Config.get(:default_shard_limit))

    case Mosaic.ShardRouter.find_similar_shards(query_embedding, shard_limit, opts) do
      {:ok, shards} ->
        # Retrieve candidates from shards
        candidates = retrieve_from_shards(shards, query_embedding, limit * 3)

        # Apply hybrid ranking
        ranked = Ranker.rank(candidates, context, ranker)

        {:ok, Enum.take(ranked, limit)}

      {:error, _} = err ->
        err
    end
  end

  defp retrieve_from_shards(shards, query_embedding, limit) do
    shards
    |> Task.async_stream(fn shard ->
      search_shard(shard, query_embedding, limit)
    end, ordered: false, timeout: 10_000)
    |> Enum.flat_map(fn
      {:ok, {:ok, results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end)
  end

  defp search_shard(shard, query_embedding, limit) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        results = do_vector_search(conn, query_embedding, limit)
        Mosaic.ConnectionPool.checkin(shard.path, conn)
        {:ok, Enum.map(results, &Map.put(&1, :shard_id, shard.id))}

      error ->
        Logger.warning("Failed to search shard #{shard.id}: #{inspect(error)}")
        {:error, []}
    end
  end

  defp do_vector_search(conn, query_embedding, limit) do
    vector_json = Jason.encode!(query_embedding)
    sql = """
    SELECT d.id, d.text, d.metadata, d.created_at, d.pagerank, v.distance
    FROM vss_vectors v
    JOIN documents d ON d.rowid = v.rowid
    WHERE vss_search(v.vec, ?) 
    LIMIT ?
    """

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, [vector_json, limit])
    rows = fetch_all_rows(conn, stmt)
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

  defp fetch_all_rows(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp build_cache_key(query_text, opts, ranker) do
    components = [
      query_text,
      Keyword.get(opts, :limit, 20),
      ranker.fusion,
      :erlang.phash2(ranker.weights)
    ]
    "query:#{:erlang.phash2(components)}"
  end

  defp extract_terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/) 
    |> Enum.filter(&(String.length(&1) > 2))
  end

  defp distance_to_similarity(nil), do: 0.0
  defp distance_to_similarity(d) when is_number(d), do: 1.0 / (1.0 + d)

  defp safe_decode(nil), do: %{}
  defp safe_decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
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
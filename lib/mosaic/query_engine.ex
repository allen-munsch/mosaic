defmodule Mosaic.QueryEngine do
  use GenServer
  require Logger
  @behaviour Mosaic.QueryEngine.Behaviour

  alias Mosaic.Ranking.Ranker
  alias Mosaic.QueryEngine.Helpers # Alias for new helper module

  defstruct [
    :cache,           # Cache implementation module
    :ranker,          # Ranker configuration
    :cache_ttl,
    :cache_name       # Name of the cache process
  ]

  def invalidate_cache(shard_id) do
    GenServer.cast(__MODULE__, {:invalidate, shard_id})
  end

  def handle_cast({:invalidate, _shard_id}, state) do
    # Invalidate all cache entries that might be affected by this shard_id.
    # For now, we will clear the entire cache for simplicity,
    # but a more granular invalidation strategy could be implemented here.
    state.cache.clear(state.cache_name)
    {:noreply, state}
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    cache_impl = Keyword.get(opts, :cache, Mosaic.Cache.ETS)
    cache_ttl = Keyword.get(opts, :cache_ttl, 300)
    ranker = Keyword.get(opts, :ranker, Ranker.new())
    cache_name = Keyword.get(opts, :cache_name, cache_impl) # Default to module name if not provided

    state = %__MODULE__{
      cache: cache_impl,
      ranker: ranker,
      cache_ttl: cache_ttl,
      cache_name: cache_name
    }

    {:ok, state}
  end

  @doc """
  Executes a query, handling caching, embedding generation, shard routing, and ranking.
  This is the primary interface for initiating a query within the system.
  """
  def execute_query(query_text, opts \\ []) do
    GenServer.call(__MODULE__, {:execute_query, query_text, opts}, 30_000)
  end

  def handle_call({:execute_query, query_text, opts}, _from, state) do
    result = p_orchestrate_query(query_text, opts, state.ranker, state)
    {:reply, result, state}
  end

  # Removed search/2 and search_with_ranker/3 public functions
  # as Mosaic.Search will now be the public API.

  defp p_orchestrate_query(query_text, opts, ranker, state) do
    limit = Keyword.get(opts, :limit, 20)
    skip_cache = Keyword.get(opts, :skip_cache, false)
    cache_key = Helpers.build_cache_key(query_text, opts, ranker)

    # Check cache
    unless skip_cache do
      case state.cache.get(cache_key, state.cache_name) do # Pass cache_name to cache
        {:ok, cached} ->
          Logger.debug("Cache hit for query: #{query_text}")
          {:ok, cached}

        :miss ->
          execute_search_and_cache(query_text, opts, ranker, cache_key, limit, state)
      end
    else
      execute_search_without_cache(query_text, opts, ranker, limit)
    end
  end

  defp execute_search_and_cache(query_text, opts, ranker, cache_key, limit, state) do
    case execute_search_without_cache(query_text, opts, ranker, limit) do
      {:ok, results} = success ->
        state.cache.put(cache_key, results, state.cache_ttl, state.cache_name) # Pass cache_name to cache
        success

      error ->
        error
    end
  end

  defp execute_search_without_cache(query_text, opts, ranker, limit) do
    # Generate embedding
    query_embedding = Mosaic.EmbeddingService.encode(query_text)
    query_terms = Helpers.extract_terms(query_text)

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
    case Mosaic.Resilience.checkout(shard.path) do
      {:ok, conn} ->
        results = do_vector_search(conn, query_embedding, limit)
        Mosaic.Resilience.checkin(shard.path, conn)
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
        metadata: Helpers.safe_decode(metadata),
        created_at: Helpers.parse_datetime(created_at),
        pagerank: pagerank || 0.0,
        similarity: Helpers.distance_to_similarity(distance)
      }
    end)
  end

  defp fetch_all_rows(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end
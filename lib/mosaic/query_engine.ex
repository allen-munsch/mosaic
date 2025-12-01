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

  alias Mosaic.Grounding.Reference
  
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
    query_embedding = Mosaic.EmbeddingService.encode(query_text)
    query_terms = Helpers.extract_terms(query_text)
    
    # Granularity level (default paragraph for RAG)
    level = Keyword.get(opts, :level, :paragraph)
    expand_context = Keyword.get(opts, :expand_context, true)
    
    context = %{
      query_text: query_text,
      query_terms: query_terms,
      query_embedding: query_embedding,
      level: level
    }
    
    shard_limit = Keyword.get(opts, :shard_limit, Mosaic.Config.get(:default_shard_limit))
    
    case Mosaic.ShardRouter.find_similar_shards(query_embedding, shard_limit, Keyword.put(opts, :level, level)) do
      {:ok, shards} ->
        candidates = retrieve_chunks_from_shards(shards, query_embedding, level, limit * 3)
        ranked = Ranker.rank(candidates, context, ranker)
        results = Enum.take(ranked, limit)
        
        if expand_context do
          {:ok, expand_with_grounding(results, shards)}
        else
          {:ok, results}
        end
      
      {:error, _} = err -> err
    end
  end
  
  defp retrieve_chunks_from_shards(shards, query_embedding, level, limit) do
    shards
    |> Task.async_stream(fn shard ->
      search_shard_chunks(shard, query_embedding, level, limit)
    end, ordered: false, timeout: 10_000)
    |> Enum.flat_map(fn
      {:ok, {:ok, results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end)
  end
  
  defp search_shard_chunks(shard, query_embedding, level, limit) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        results = do_chunk_vector_search(conn, query_embedding, level, limit)
        Mosaic.ConnectionPool.checkin(shard.path, conn)
        {:ok, Enum.map(results, &Map.put(&1, :shard_id, shard.id))}
      error ->
        Logger.warning("Failed to search shard #{shard.id}: #{inspect(error)}")
        {:error, []}
    end
  end
  
  defp do_chunk_vector_search(conn, query_embedding, level, limit) do
    vector_json = Jason.encode!(query_embedding)
    
    sql = """
      SELECT c.id, c.doc_id, c.parent_id, c.level, c.text, 
             c.start_offset, c.end_offset, c.pagerank,
             vec_distance_cosine(vc.embedding, ?) as distance
      FROM chunks c
      JOIN vec_chunks vc ON c.id = vc.id
      WHERE c.level = ?
      ORDER BY distance ASC
      LIMIT ?
    """
    
    case Mosaic.DB.query(conn, sql, [vector_json, Atom.to_string(level), limit]) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, doc_id, parent_id, level_str, text, start_off, end_off, pagerank, distance] ->
          %{
            id: id,
            doc_id: doc_id,
            parent_id: parent_id,
            level: String.to_atom(level_str),
            text: text,
            start_offset: start_off,
            end_offset: end_off,
            pagerank: pagerank || 0.0,
            similarity: Helpers.distance_to_similarity(distance)
          }
        end)
      {:error, err} ->
        Logger.error("Error during chunk vector search: #{inspect(err)}")
        []
    end
  end
  
  defp expand_with_grounding(results, shards) do
    Enum.map(results, fn result ->
      shard = Enum.find(shards, &(&1.id == result.shard_id))
      grounding = fetch_grounding(result, shard)
      Map.put(result, :grounding, grounding)
    end)
  end
  
  defp fetch_grounding(result, shard) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        doc_text = fetch_doc_text(conn, result.doc_id)
        parent_context = fetch_parent_context(conn, result.parent_id)
        Mosaic.ConnectionPool.checkin(shard.path, conn)
        
        %Reference{
          chunk_id: result.id,
          doc_id: result.doc_id,
          doc_text: doc_text,
          chunk_text: result.text,
          start_offset: result.start_offset,
          end_offset: result.end_offset,
          parent_context: parent_context,
          level: result.level
        }
      _ -> nil
    end
  end
  
  defp fetch_doc_text(conn, doc_id) do
    case Mosaic.DB.query_one(conn, "SELECT text FROM documents WHERE id = ?", [doc_id]) do
      {:ok, text} -> text
      _ -> nil
    end
  end
  
  defp fetch_parent_context(_conn, nil), do: nil
  defp fetch_parent_context(conn, parent_id) do
    case Mosaic.DB.query_row(conn, 
      "SELECT text, start_offset, end_offset FROM chunks WHERE id = ?", [parent_id]) do
      {:ok, [text, start_off, end_off]} -> 
        %{text: text, start_offset: start_off, end_offset: end_off}
      _ -> nil
    end
  end
  

end
defmodule Mosaic.QueryEngine do
  use GenServer
  require Logger
  @behaviour Mosaic.QueryEngine.Behaviour

  alias Mosaic.Ranking.Ranker
  # Alias for new helper module
  alias Mosaic.QueryEngine.Helpers

  defstruct [
    # Cache implementation module
    :cache,
    # Ranker configuration
    :ranker,
    :cache_ttl,
    # Name of the cache process
    :cache_name,
    # Index strategy module
    :index_strategy,
    # State managed by the index strategy
    :index_state
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
    cache_name = Keyword.get(opts, :cache_name, cache_impl)
    cache_ttl = Keyword.get(opts, :cache_ttl, 300)
    ranker = Keyword.get(opts, :ranker, Ranker.new())

    strategy_module = Keyword.get(opts, :index_strategy, "centroid")
    index_strategy = case strategy_module do
      "quantized" -> Mosaic.Index.Strategy.Quantized
      _ -> Mosaic.Index.Strategy.Centroid
    end

    {:ok, index_state} = index_strategy.init(opts)

    state = %__MODULE__{
      cache: cache_impl,
      ranker: ranker,
      cache_ttl: cache_ttl,
      cache_name: cache_name,
      index_strategy: index_strategy,
      index_state: index_state
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
      # Pass cache_name to cache
      case state.cache.get(cache_key, state.cache_name) do
        {:ok, cached} ->
          Logger.debug("Cache hit for query: #{query_text}")
          {:ok, cached}

        :miss ->
          execute_search_and_cache(query_text, opts, ranker, cache_key, limit, state)
      end
    else
      execute_search_without_cache(query_text, opts, ranker, limit, state)
    end
  end

  defp execute_search_and_cache(query_text, opts, ranker, cache_key, limit, state) do
    case execute_search_without_cache(query_text, opts, ranker, limit, state) do
      {:ok, results} = success ->
        # Pass cache_name to cache
        state.cache.put(cache_key, results, state.cache_ttl, state.cache_name)
        success


      error ->
        error
    end
  end

  defp execute_search_without_cache(query_text, opts, ranker, limit, state) do
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

    # Use the configured index strategy to find candidates
    case state.index_strategy.find_candidates(
           query_embedding,
           Keyword.merge(opts, level: level, query_terms: query_terms),
           state.index_state
         ) do
      {:ok, candidates} ->
        ranked = Ranker.rank(candidates, context, ranker)
        results = ranked |> Enum.take(limit) |> deduplicate_results()

        if expand_context do
          {:ok, expand_with_grounding(results, [])} # Shards are not relevant in this context anymore for grounding
        else
          {:ok, Enum.map(results, &Map.put(&1, :grounding, nil))}
        end

      {:error, _} = err ->
        err
    end
  end


  defp expand_with_grounding(results, state) do
    Enum.map(results, fn result ->
      grounding = fetch_grounding(result, state)
      Map.put(result, :grounding, grounding)
    end)
  end

  defp fetch_grounding(result, state) do
    case state.index_strategy do
      Mosaic.Index.Strategy.Centroid ->
        shard_id = result.shard_id
        case Mosaic.ShardRouter.list_all_shards() do
          shards ->
            shard = Enum.find(shards, &(&1.id == shard_id))
            if shard do
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
            else
              nil
            end
        end
      Mosaic.Index.Strategy.Quantized ->
        # For quantized strategy, `result` should contain `cell_path`
        # and `doc_id` directly, as text is not stored in cell.
        # Grounding would involve looking up the original document if needed.
        # For now, return a simplified grounding based on metadata.
        # A full implementation would need a mechanism to retrieve original document text.
        %Reference{
          chunk_id: result.id,
          doc_id: result.id, # In quantized, doc_id is chunk_id
          doc_text: "Text not available in quantized cell for grounding directly.",
          chunk_text: result.metadata["text"] || "Text not available.",
          start_offset: 0,
          end_offset: 0,
          parent_context: nil,
          level: :document # Assuming document level for quantized cells
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
    case Mosaic.DB.query_row(
           conn,
           "SELECT text, start_offset, end_offset FROM chunks WHERE id = ?",
           [parent_id]
         ) do
      {:ok, [text, start_off, end_off]} ->
        %{text: text, start_offset: start_off, end_offset: end_off}

      _ ->
        nil
    end
  end

  defp deduplicate_results(results) do
    Enum.uniq_by(results, fn r -> {r.doc_id, r.start_offset, r.end_offset} end)
  end
end

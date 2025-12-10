defmodule Mosaic.Index.Strategy.Centroid do
  @behaviour Mosaic.Index.Strategy
  require Logger
  alias Mosaic.QueryEngine.Helpers

  # Delegate to existing ShardRouter + Indexer logic
  # Minimal changes - just adapter pattern
  
  @impl true
  def init(_opts) do
    # Current initialization would involve starting ShardRouter and Indexer if they were not already supervised
    # Since they are, we just need to ensure their processes are registered.
    # For now, simply return an empty state as they manage their own state.
    {:ok, %{}}
  end
  
  @impl true
  def find_candidates(query_embedding, opts, _state) do
    limit = Keyword.get(opts, :limit, Mosaic.Config.get(:default_result_limit))
    shard_limit = Keyword.get(opts, :shard_limit, Mosaic.Config.get(:default_shard_limit))
    level = Keyword.get(opts, :level, :paragraph)
    query_terms = Keyword.get(opts, :query_terms, [])

    case Mosaic.ShardRouter.find_similar_shards_sync(
           query_embedding,
           shard_limit,
           Keyword.merge(opts, level: level, query_terms: query_terms)
         ) do
      shards ->
        candidates = retrieve_chunks_from_shards(shards, query_embedding, level, limit * 3)
        {:ok, candidates}
    end
  end

  @impl true
  def index_document(doc, _embedding, _state) do
    # Assuming doc is %{id: ..., text: ..., metadata: ...}
    # embedding here is the document embedding, not chunk embeddings
    case Mosaic.Indexer.index_document(doc.id, doc.text, doc.metadata) do
      {:ok, _} -> {:ok, nil} # State is not used here for centroid

    end
  end

  @impl true
  def index_batch(docs, state) do
    Enum.reduce_while(docs, {:ok, state}, fn {doc, embedding}, {:ok, acc_state} ->
      case index_document(doc, embedding, acc_state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def delete_document(doc_id, _state) do
    Mosaic.Indexer.delete_document(doc_id)
  end

  @impl true
  def get_stats(_state) do
    # Placeholder for now, can delegate to existing stats if available
    # For centroid strategy, this could involve ShardRouter stats
    %{}
  end

  @impl true
  def serialize(state) do
    {:ok, :erlang.term_to_binary(state)}
  end

  @impl true
  def deserialize(data, _opts) do
    {:ok, :erlang.binary_to_term(data)}
  end

  @impl true
  def optimize(state) do
    {:ok, state}
  end

  # Helper functions moved from QueryEngine
  defp retrieve_chunks_from_shards(shards, query_embedding, level, limit) do
    shards
    |> Task.async_stream(
      fn shard ->
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
      SELECT c.id, c.doc_id, c.parent_id, c.level, c.text, c.start_offset, c.end_offset, c.pagerank, d.created_at, d.metadata, vec_distance_cosine(vc.embedding, ?) as distance
      FROM chunks c
      JOIN vec_chunks vc ON c.id = vc.id
      JOIN documents d ON c.doc_id = d.id
      WHERE c.level = ?
      ORDER BY distance ASC
      LIMIT ?
    """

    case Mosaic.DB.query(conn, sql, [vector_json, Atom.to_string(level), limit]) do
      {:ok, rows} ->
        Enum.map(rows, fn [
                            id,
                            doc_id,
                            parent_id,
                            level_str,
                            text,
                            start_off,
                            end_off,
                            pagerank,
                            created_at,
                            metadata,
                            distance
                          ] ->
          %{
            id: id,
            doc_id: doc_id,
            parent_id: parent_id,
            level: String.to_atom(level_str),
            text: text,
            start_offset: start_off,
            end_offset: end_off,
            pagerank: pagerank || 0.0,
            created_at: Helpers.parse_datetime(created_at),
            metadata: Helpers.safe_decode(metadata),
            similarity: Helpers.distance_to_similarity(distance)
          }
        end)

      {:error, err} ->
        Logger.error("Chunk vector search error: #{inspect(err)}")
        []
    end
  end
end

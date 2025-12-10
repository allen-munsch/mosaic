defmodule Mosaic.Indexer do
  use GenServer
  require Logger

  @max_docs_per_shard 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    :ets.new(:indexer_state, [:set, :public, :named_table])
    :ets.insert(:indexer_state, {:active_shard, nil, nil, 0})
    {:ok, %{}}
  end

  # Public API for strategies
  def index_document_to_shard(conn, shard_path, id, text, metadata, embedding) do
    do_index_document_to_shard(conn, shard_path, id, text, metadata, embedding)
  end

  def delete_document_from_shard(conn, doc_id) do
    do_delete_document_from_shard(conn, doc_id)
  end

  # Original index_document is now handled by strategy through Strategy.Centroid adapter
  def index_document(id, text, metadata \\ %{}) do
    {_shard_id, shard_path, conn} = get_or_create_shard()
    do_index_document_to_shard(conn, shard_path, id, text, metadata, nil)
    register_single_doc_shard(shard_path, id, text)
    {:ok, %{id: id, status: :indexed, shard_path: shard_path}}
  end

  def delete_document(doc_id) do
    # This will be delegated to the active strategy.
    # For now, it will look up all existing shards and try to delete.
    # This is a temporary solution until strategies handle deletion more robustly.
    shards_paths = Mosaic.ShardRouter.list_all_shard_paths() # New function in ShardRouter
    Enum.each(shards_paths, fn shard_path ->
      case Mosaic.ConnectionPool.checkout(shard_path) do
        {:ok, conn} ->
          do_delete_document_from_shard(conn, doc_id)
          Mosaic.ConnectionPool.checkin(shard_path, conn)
        _ ->
          :ok
      end
    end)
    :ok
  end

  def update_document(id, text, metadata \\ %{}) do
    delete_document(id)
    index_document(id, text, metadata)
  end

  def index_documents(documents, opts \\ []) do
    shard_id = Keyword.get(opts, :shard_id, generate_shard_id())
    shard_path = shard_path_for(shard_id)

    with {:ok, ^shard_path} <- Mosaic.StorageManager.create_shard(shard_path),
         {:ok, conn} <- Mosaic.ConnectionPool.checkout(shard_path) do
      Mosaic.DB.execute(conn, "BEGIN IMMEDIATE")
      Enum.each(documents, fn {id, text, meta} ->
        do_index_document_to_shard(conn, shard_path, id, text, meta, nil)
      end)
      Mosaic.DB.execute(conn, "COMMIT")
      Mosaic.ConnectionPool.checkin(shard_path, conn)

      register_batch_shard(shard_id, shard_path, documents)
      Logger.info("Indexed #{length(documents)} documents in shard #{shard_id}")
      {:ok, %{shard_id: shard_id, shard_path: shard_path, doc_count: length(documents)}}
    end
  end

  defp register_batch_shard(shard_id, shard_path, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    terms = texts
      |> Enum.flat_map(&String.split(&1, ~r/\W+/))
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(&(String.length(&1) > 2))
    bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)
    
    centroids = Mosaic.Index.Centroid.Calculator.compute_level_centroids(shard_path)

    Mosaic.ShardRouter.register_shard(%{
      id: shard_id,
      path: shard_path,
      centroids: centroids,
      doc_count: length(documents),
      bloom_filter: bloom
    })

    Mosaic.QueryEngine.invalidate_cache(shard_id)
    :ok
  end

  defp register_single_doc_shard(shard_path, _id, text) do
    # Only register if it's a new shard or doc_count just incremented past 0
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, shard_id, ^shard_path, 1}] -> # First doc in this shard
        terms = text |> String.split(~r/\W+/) |> Enum.map(&String.downcase/1) |> Enum.filter(&(String.length(&1) > 2))
        bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)
        
        centroids = Mosaic.Index.Centroid.Calculator.compute_level_centroids(shard_path)

        Mosaic.ShardRouter.register_shard(%{
          id: shard_id,
          path: shard_path,
          centroids: centroids,
          doc_count: 1,
          bloom_filter: bloom
        })
        Mosaic.QueryEngine.invalidate_cache(shard_id)
      _ -> :ok
    end
  end


  alias Mosaic.Chunking.{Chunk, Splitter}

  defp do_index_document_to_shard(conn, _shard_path, id, text, metadata, provided_embedding) do
    Mosaic.DB.execute(conn, "BEGIN IMMEDIATE")

    try do
      :ok =
        Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)", [
          id,
          text,
          Jason.encode!(metadata)
        ])

      %{document: doc_chunk, paragraphs: paragraphs, sentences: sentences} =
        Splitter.split(id, text)

      all_chunks = [doc_chunk | paragraphs ++ sentences]
      
      embeddings = if provided_embedding do
        # If a single embedding is provided, apply it to the document chunk
        # and generate for others or handle accordingly. For simplicity here,
        # we'll assume provided_embedding is for the document itself and compute others.
        # This part might need refinement based on how strategies provide embeddings.
        Logger.warning("Provided embedding will only be used for the document chunk. Other chunks will be re-encoded.")
        texts = Enum.map(all_chunks, & &1.text)
        [provided_embedding | Mosaic.EmbeddingService.encode_batch(tl(texts))]
      else
        texts = Enum.map(all_chunks, & &1.text)
        Mosaic.EmbeddingService.encode_batch(texts)
      end

      all_chunks
      |> Enum.zip(embeddings)
      |> Enum.each(fn {chunk, embedding} -> insert_chunk(conn, chunk, embedding) end)

      Mosaic.DB.execute(conn, "COMMIT")
      increment_doc_count()
      Logger.debug("Indexed document #{id} with #{length(all_chunks)} chunks")
    rescue
      e ->
        Mosaic.DB.execute(conn, "ROLLBACK")
        Logger.error("Failed to index #{id}: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
  end

  defp do_delete_document_from_shard(conn, doc_id) do
    Mosaic.DB.execute(
      conn,
      "DELETE FROM vec_chunks WHERE id IN (SELECT id FROM chunks WHERE doc_id = ?)",
      [doc_id]
    )

    Mosaic.DB.execute(conn, "DELETE FROM chunks WHERE doc_id = ?", [doc_id])
    Mosaic.DB.execute(conn, "DELETE FROM documents WHERE id = ?", [doc_id])
    :ok
  end

  defp insert_chunk(conn, %Chunk{} = chunk, embedding) do
    :ok =
      Mosaic.DB.execute(
        conn,
        """
          INSERT INTO chunks (id, doc_id, parent_id, level, text, start_offset, end_offset)
          VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          chunk.id,
          chunk.doc_id,
          chunk.parent_id,
          Atom.to_string(chunk.level),
          chunk.text,
          chunk.start_offset,
          chunk.end_offset
        ]
      )

    :ok =
      Mosaic.DB.execute(
        conn,
        "INSERT INTO vec_chunks (id, embedding) VALUES (?, ?)",
        [chunk.id, Jason.encode!(embedding)]
      )
  end

  defp get_or_create_shard do
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, nil, nil, _}] ->
        create_new_shard()

      [{:active_shard, _id, _path, count}] when count >= @max_docs_per_shard ->
        create_new_shard()

      [{:active_shard, shard_id, shard_path, _count}] ->
        case Mosaic.ConnectionPool.checkout(shard_path) do
          {:ok, conn} ->
            {shard_id, shard_path, conn}

          {:error, _reason} ->
            Logger.warning(
              "Failed to checkout connection for shard #{shard_id}, creating new shard."
            )

            create_new_shard()
        end
    end
  end

  defp create_new_shard do
    shard_id = generate_shard_id()
    shard_path = shard_path_for(shard_id)
    Logger.warning(">>> Calling StorageManager.create_shard(#{shard_path})")
    result = Mosaic.StorageManager.create_shard(shard_path)
    Logger.warning(">>> StorageManager returned: #{inspect(result)}")
    {:ok, ^shard_path} = result
    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
    :ets.insert(:indexer_state, {:active_shard, shard_id, shard_path, 0})
    {shard_id, shard_path, conn}
  end

  defp increment_doc_count do
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, id, path, count}] ->
        :ets.insert(:indexer_state, {:active_shard, id, path, count + 1})

      _ ->
        :ok
    end
  end

  defp generate_shard_id, do: "shard_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
  defp shard_path_for(shard_id), do: Path.join(Mosaic.Config.get(:storage_path), "#{shard_id}.db")
end

# New module for centroid calculation
defmodule Mosaic.Index.Centroid.Calculator do
  require Logger

  def compute_level_centroids(shard_path) do
    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)

    centroids =
      [:document, :paragraph, :sentence]
      |> Enum.map(fn level ->
        embeddings = fetch_level_embeddings(conn, level)
        centroid = if Enum.empty?(embeddings), do: nil, else: compute_centroid(embeddings)
        {level, centroid}
      end)
      |> Enum.reject(fn {_, c} -> is_nil(c) end)
      |> Map.new()

    Mosaic.ConnectionPool.checkin(shard_path, conn)

    # Default centroid if no chunks found
    if map_size(centroids) == 0 do
      %{document: List.duplicate(0.0, Mosaic.Config.get(:embedding_dim))}
    else
      centroids
    end
  end

  defp fetch_level_embeddings(conn, level) do
    case Mosaic.DB.query(conn, """
      SELECT vc.embedding FROM vec_chunks vc
      JOIN chunks c ON vc.id = c.id
      WHERE c.level = ?
      LIMIT 1000
    """, [Atom.to_string(level)]) do
      {:ok, rows} ->
        Enum.map(rows, fn [emb] ->
          case emb do
            binary when is_binary(binary) -> decode_vec_binary(binary)
            _ -> emb
          end
        end)
      {:error, err} ->
        Logger.error("Error fetching level embeddings: #{inspect(err)}")
        []
    end
  end

  defp decode_vec_binary(binary) do
    # sqlite-vec stores as little-endian float32 array
    for <<f::little-float-32 <- binary>>, do: f
  end

  defp compute_centroid(embeddings) do
    dim = length(hd(embeddings))
    count = length(embeddings)

    embeddings
    |> Enum.reduce(List.duplicate(0.0, dim), fn emb, acc ->
      Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / count))
  end
end

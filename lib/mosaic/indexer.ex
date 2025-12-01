defmodule Mosaic.Indexer do
  use GenServer
  require Logger

  @max_docs_per_shard 10_000
  @max_concurrent 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    :ets.new(:indexer_state, [:set, :public, :named_table])
    :ets.insert(:indexer_state, {:active_shard, nil, nil, 0})
    {:ok, %{semaphore: @max_concurrent}}
  end

  def index_document(id, text, metadata \\ %{}) do
    case GenServer.call(__MODULE__, :acquire, 5000) do
      :ok ->
        Task.start(fn ->
          try do
            do_index_document(id, text, metadata)
          after
            GenServer.cast(__MODULE__, :release)
          end
        end)
        {:ok, %{id: id, status: :queued}}
      :full ->
        {:error, :queue_full}
    end
  end

  def index_documents(documents, opts \\ []) do
    shard_id = Keyword.get(opts, :shard_id, generate_shard_id())
    shard_path = shard_path_for(shard_id)
    with {:ok, ^shard_path} <- Mosaic.StorageManager.create_shard(shard_path),
         {:ok, conn} <- Mosaic.ConnectionPool.checkout(shard_path),
         :ok <- insert_documents(conn, documents),
         :ok <- register_shard(shard_id, shard_path, documents) do
      Mosaic.ConnectionPool.checkin(shard_path, conn)
      Logger.info("Indexed #{length(documents)} documents in shard #{shard_id}")
      {:ok, %{shard_id: shard_id, shard_path: shard_path, doc_count: length(documents)}}
    end
  end

  def handle_call(:acquire, _from, %{semaphore: 0} = state) do
    {:reply, :full, state}
  end
  def handle_call(:acquire, _from, %{semaphore: n} = state) do
    {:reply, :ok, %{state | semaphore: n - 1}}
  end

  def handle_cast(:release, %{semaphore: n} = state) do
    {:noreply, %{state | semaphore: min(n + 1, @max_concurrent)}}
  end

  alias Mosaic.Chunking.{Chunk, Splitter}

  defp do_index_document(id, text, metadata) do
    {_shard_id, shard_path, conn} = get_or_create_shard()

    :ok = Mosaic.DB.execute(conn,
      "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)",
      [id, text, Jason.encode!(metadata)])

    %{document: doc_chunk, paragraphs: paragraphs, sentences: sentences} =
      Splitter.split(id, text)

    all_chunks = [doc_chunk | paragraphs ++ sentences]
    texts = Enum.map(all_chunks, & &1.text)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)

    all_chunks
    |> Enum.zip(embeddings)
    |> Enum.each(fn {chunk, embedding} ->
      insert_chunk(conn, chunk, embedding)
    end)

    Mosaic.ConnectionPool.checkin(shard_path, conn)
    increment_doc_count()
    Logger.debug("Indexed document #{id} with #{length(all_chunks)} chunks")
  rescue
    e -> Logger.error("Failed to index #{id}: #{inspect(e)}")
  end

  defp insert_chunk(conn, %Chunk{} = chunk, embedding) do
    :ok = Mosaic.DB.execute(conn, """
      INSERT INTO chunks (id, doc_id, parent_id, level, text, start_offset, end_offset)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    """, [chunk.id, chunk.doc_id, chunk.parent_id, Atom.to_string(chunk.level),
          chunk.text, chunk.start_offset, chunk.end_offset])

    :ok = Mosaic.DB.execute(conn,
      "INSERT INTO vec_chunks (id, embedding) VALUES (?, ?)",
      [chunk.id, Jason.encode!(embedding)])
  end

  defp get_or_create_shard do
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, nil, nil, _}] -> create_new_shard()
      [{:active_shard, _id, _path, count}] when count >= @max_docs_per_shard -> create_new_shard()
      [{:active_shard, shard_id, shard_path, _count}] ->
        {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
        {shard_id, shard_path, conn}
    end
  end

  defp create_new_shard do
    shard_id = generate_shard_id()
    shard_path = shard_path_for(shard_id)
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
    :ets.insert(:indexer_state, {:active_shard, shard_id, shard_path, 0})
    {shard_id, shard_path, conn}
  end

  defp increment_doc_count do
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, id, path, count}] -> :ets.insert(:indexer_state, {:active_shard, id, path, count + 1})
      _ -> :ok
    end
  end

  # FIXED: Now creates chunks instead of inserting into non-existent vec_documents
  defp insert_documents(conn, documents) do
    Enum.each(documents, fn {id, text, meta} ->
      :ok = Mosaic.DB.execute(conn,
        "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)",
        [id, text, Jason.encode!(meta)])

      %{document: doc_chunk, paragraphs: paragraphs, sentences: sentences} =
        Splitter.split(id, text)

      all_chunks = [doc_chunk | paragraphs ++ sentences]
      texts = Enum.map(all_chunks, & &1.text)
      embeddings = Mosaic.EmbeddingService.encode_batch(texts)

      all_chunks
      |> Enum.zip(embeddings)
      |> Enum.each(fn {chunk, embedding} ->
        insert_chunk(conn, chunk, embedding)
      end)
    end)
    :ok
  end

  defp register_shard(shard_id, shard_path, documents) do
    centroids = compute_level_centroids(shard_path)

    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    terms = texts
    |> Enum.flat_map(&String.split(&1, ~r/\W+/))
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(String.length(&1) > 2))

    bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)

    GenServer.cast(Mosaic.ShardRouter, {:register_shard, %{
      id: shard_id,
      path: shard_path,
      centroids: centroids,
      doc_count: length(documents),
      bloom_filter: bloom
    }})

    Mosaic.QueryEngine.invalidate_cache(shard_id)
    :ok
  end

  defp compute_level_centroids(shard_path) do
    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)

    centroids = [:document, :paragraph, :sentence]
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
      {:ok, rows} -> Enum.map(rows, fn [emb] -> Jason.decode!(emb) end)
      {:error, err} ->
        Logger.error("Error fetching level embeddings: #{inspect(err)}")
        []
    end
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



  defp generate_shard_id, do: "shard_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
  defp shard_path_for(shard_id), do: Path.join(Mosaic.Config.get(:storage_path), "#{shard_id}.db")
end

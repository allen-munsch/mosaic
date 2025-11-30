defmodule Mosaic.Indexer do
  use GenServer
  require Logger

  @max_docs_per_shard 10_000
  @max_concurrent 8  # Limit concurrent embedding calls

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

  defp do_index_document(id, text, metadata) do
    {_shard_id, shard_path, conn} = get_or_create_shard()
    embedding = Mosaic.EmbeddingService.encode(text)
    :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata, embedding) VALUES (?, ?, ?, ?)", [id, text, Jason.encode!(metadata), Jason.encode!(embedding)])
    :ok = Mosaic.DB.execute(conn, "INSERT INTO vec_documents (id, embedding) VALUES (?, ?)", [id, Jason.encode!(embedding)])
    Mosaic.ConnectionPool.checkin(shard_path, conn)
    increment_doc_count()
    Logger.debug("Indexed document #{id}")
  rescue
    e -> Logger.error("Failed to index #{id}: #{inspect(e)}")
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

  defp insert_documents(conn, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)
    Enum.zip(documents, embeddings) |> Enum.each(fn {{id, text, meta}, emb} ->
      :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata, embedding) VALUES (?, ?, ?, ?)", [id, text, Jason.encode!(meta), Jason.encode!(emb)])
      :ok = Mosaic.DB.execute(conn, "INSERT INTO vec_documents (id, embedding) VALUES (?, ?)", [id, Jason.encode!(emb)])
    end)
    :ok
  end

  defp register_shard(shard_id, shard_path, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)
    dim = length(hd(embeddings))
    centroid = embeddings |> Enum.reduce(List.duplicate(0.0, dim), fn emb, acc -> Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end) end) |> Enum.map(&(&1 / length(embeddings)))
    terms = texts |> Enum.flat_map(&String.split(&1, ~r/\W+/)) |> Enum.map(&String.downcase/1) |> Enum.filter(&(String.length(&1) > 2))
    bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)
    GenServer.cast(Mosaic.ShardRouter, {:register_shard, %{id: shard_id, path: shard_path, centroid: centroid, doc_count: length(documents), bloom_filter: bloom}})
    Mosaic.QueryEngine.invalidate_cache(shard_id)
    :ok
  end

  defp generate_shard_id, do: "shard_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
  defp shard_path_for(shard_id), do: Path.join(Mosaic.Config.get(:storage_path), "#{shard_id}.db")
end

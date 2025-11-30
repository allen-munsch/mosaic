defmodule Mosaic.Indexer do
  @moduledoc """
  Handles document indexing with async processing to avoid bottlenecks.
  """
  use GenServer
  require Logger

  @max_docs_per_shard 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    :ets.new(:indexer_state, [:set, :public, :named_table])
    :ets.insert(:indexer_state, {:active_shard, nil, nil, 0})
    {:ok, %{}}
  end

  def index_document(id, text, metadata \\ %{}) do
    Task.start(fn -> do_index_document(id, text, metadata) end)
    {:ok, %{id: id, status: :queued}}
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

  defp do_index_document(id, text, metadata) do
    {shard_id, shard_path, conn} = get_or_create_shard()
    embedding = Mosaic.EmbeddingService.encode(text)
    :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata, embedding) VALUES (?, ?, ?, ?)", [id, text, Jason.encode!(metadata), Jason.encode!(embedding)])
    :ok = Mosaic.DB.execute(conn, "INSERT INTO vec_documents (id, embedding) VALUES (?, ?)", [id, Jason.encode!(embedding)])
    Mosaic.ConnectionPool.checkin(shard_path, conn)
    increment_doc_count()
    Logger.debug("Indexed document #{id} in shard #{shard_id}")
  rescue
    e -> Logger.error("Failed to index document #{id}: #{inspect(e)}")
  end

  defp get_or_create_shard do
    case :ets.lookup(:indexer_state, :active_shard) do
      [{:active_shard, nil, nil, _}] -> create_new_shard()
      [{:active_shard, _shard_id, _shard_path, count}] when count >= @max_docs_per_shard ->
        create_new_shard()
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
    Logger.info("Created new shard: #{shard_id}")
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
    Enum.zip(documents, embeddings)
    |> Enum.each(fn {{id, text, meta}, embedding} ->
      :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata, embedding) VALUES (?, ?, ?, ?)", [id, text, Jason.encode!(meta), Jason.encode!(embedding)])
      :ok = Mosaic.DB.execute(conn, "INSERT INTO vec_documents (id, embedding) VALUES (?, ?)", [id, Jason.encode!(embedding)])
    end)
    :ok
  end

  defp register_shard(shard_id, shard_path, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)
    dim = length(hd(embeddings))
    centroid = embeddings
    |> Enum.reduce(List.duplicate(0.0, dim), fn emb, acc -> Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end) end)
    |> Enum.map(&(&1 / length(embeddings)))
    terms = texts |> Enum.flat_map(&String.split(&1, ~r/\W+/)) |> Enum.map(&String.downcase/1) |> Enum.filter(&(String.length(&1) > 2))
    bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)
    GenServer.cast(Mosaic.ShardRouter, {:register_shard, %{id: shard_id, path: shard_path, centroid: centroid, doc_count: length(documents), bloom_filter: bloom}})
    Mosaic.QueryEngine.invalidate_cache(shard_id)
    :ok
  end

  defp generate_shard_id, do: "shard_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
  defp shard_path_for(shard_id), do: Path.join(Mosaic.Config.get(:storage_path), "#{shard_id}.db")
end

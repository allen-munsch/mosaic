defmodule Mosaic.Indexer do
  @moduledoc """
  Handles document indexing: creates shards, generates embeddings, stores vectors, registers with router.
  """
  require Logger



  def index_documents(documents, opts \\ []) do
    shard_id = Keyword.get(opts, :shard_id, generate_shard_id())
    shard_path = Keyword.get(opts, :shard_path, shard_path_for(shard_id))

    with {:ok, ^shard_path} <- Mosaic.StorageManager.create_shard(shard_path),
         {:ok, conn} <- Mosaic.Resilience.checkout(shard_path),
         :ok <- insert_documents(conn, documents),
         :ok <- register_shard(shard_id, shard_path, documents) do
      Mosaic.Resilience.checkin(shard_path, conn)
      Logger.info("Indexed #{length(documents)} documents in shard #{shard_id}")
      {:ok, %{shard_id: shard_id, shard_path: shard_path, doc_count: length(documents)}}
    end
  end

  def index_document(id, text, metadata \\ %{}) do
    # Find or create active shard
    {shard_id, shard_path, conn} = get_or_create_active_shard()

    embedding = Mosaic.EmbeddingService.encode(text)
    embedding_json = Jason.encode!(embedding)

    :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)", [id, text, Jason.encode!(metadata)])

    # Get rowid of inserted doc
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT rowid FROM documents WHERE id = ?")
    :ok = Exqlite.Sqlite3.bind(stmt, [id])
    {:row, [rowid]} = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)

    # Insert into vss_vectors with JSON format
    {:ok, vss_stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO vss_vectors(rowid, vec) VALUES (?, ?)")
    :ok = Exqlite.Sqlite3.bind(vss_stmt, [rowid, embedding_json])
    :done = Exqlite.Sqlite3.step(conn, vss_stmt)
    Exqlite.Sqlite3.release(conn, vss_stmt)

    Mosaic.Resilience.checkin(shard_path, conn)
    {:ok, %{id: id, shard_id: shard_id}}
  end

  defp insert_documents(conn, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)

    Enum.zip(documents, embeddings)
    |> Enum.each(fn {{id, text, meta}, embedding} ->
      :ok = Mosaic.DB.execute(conn, "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)", [id, text, Jason.encode!(meta)])

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT rowid FROM documents WHERE id = ?")
      :ok = Exqlite.Sqlite3.bind(stmt, [id])
      {:row, [rowid]} = Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)

      # VSS requires JSON array format
      embedding_json = Jason.encode!(embedding)
      {:ok, vss_stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO vss_vectors(rowid, vec) VALUES (?, ?)")
      :ok = Exqlite.Sqlite3.bind(vss_stmt, [rowid, embedding_json])
      :done = Exqlite.Sqlite3.step(conn, vss_stmt)
      Exqlite.Sqlite3.release(conn, vss_stmt)
    end)
    :ok
  end

  defp register_shard(shard_id, shard_path, documents) do
    texts = Enum.map(documents, fn {_id, text, _meta} -> text end)
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)

    # Compute centroid (mean of all embeddings)
    dim = length(hd(embeddings))
    centroid = embeddings
    |> Enum.reduce(List.duplicate(0.0, dim), fn emb, acc ->
      Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / length(embeddings)))

    # Build bloom filter from document terms
    terms = texts
    |> Enum.flat_map(&String.split(&1, ~r/\W+/))
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(String.length(&1) > 2))
    bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)

    GenServer.cast(Mosaic.ShardRouter, {:register_shard, %{
      id: shard_id,
      path: shard_path,
      centroid: centroid,
      doc_count: length(documents),
      bloom_filter: bloom
    }})
    Mosaic.QueryEngine.invalidate_cache(shard_id)
    :ok
  end

  defp get_or_create_active_shard do
    # Simple: always create new shard for now
    # TODO: Track active shard and reuse until full
    shard_id = generate_shard_id()
    shard_path = shard_path_for(shard_id)
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    {:ok, conn} = Mosaic.Resilience.checkout(shard_path)
    {shard_id, shard_path, conn}
  end

  defp generate_shard_id do
    "shard_#{:erlang.system_time(:millisecond)}_#{:rand.uniform(1000)}"
  end

  defp shard_path_for(shard_id) do
    storage_path = Mosaic.Config.get(:storage_path)
    Path.join(storage_path, "#{shard_id}.db")
  end
end

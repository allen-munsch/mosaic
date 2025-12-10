defmodule Mosaic.Index.Quantized.Cell do
  use GenServer
  require Logger
  
  defstruct [:path, :conn, :capacity, :count]
  
  def start_link(cell_path, opts) do
    GenServer.start_link(__MODULE__, {cell_path, opts}, name: via_tuple(cell_path))
  end

  def init({cell_path, opts}) do
    File.mkdir_p!(Path.dirname(cell_path))
    {:ok, conn} = Exqlite.Sqlite3.open(cell_path)
    
    Mosaic.StorageManager.load_vec_extension(conn)
    create_schema(conn)

    # Get current count
    {:ok, [[count]]} = Mosaic.DB.query(conn, "SELECT COUNT(*) FROM documents")
    
    {:ok, %__MODULE__{
      path: cell_path,
      conn: conn,
      capacity: Keyword.get(opts, :capacity, 10_000),
      count: count
    }}
  end
  
  def insert(cell_path, id, embedding, metadata) do
    GenServer.call(via_tuple(cell_path), {:insert, id, embedding, metadata})
  end
  
  def search(cell_path, query_embedding, limit) do
    GenServer.call(via_tuple(cell_path), {:search, query_embedding, limit})
  end

  def get_info(cell_path) do
    GenServer.call(via_tuple(cell_path), :get_info)
  end

  # GenServer callbacks with SQLite operations...
  def handle_call({:insert, id, embedding, metadata}, _from, state) do
    if state.count >= state.capacity do
      {:reply, {:error, :cell_full}, state}
    else
      Mosaic.DB.execute(state.conn, "BEGIN IMMEDIATE")

      try do
        :ok = Mosaic.DB.execute(state.conn, "INSERT INTO documents (id, text, metadata) VALUES (?, ?, ?)", [
          id,
          "N/A", # Text is not stored in cell, only embedding
          Jason.encode!(metadata)
        ])

        # For FSVec, each document is a single chunk
        :ok = Mosaic.DB.execute(state.conn, "INSERT INTO chunks (id, doc_id, level, text) VALUES (?, ?, ?, ?)", [
          id,
          id,
          "document",
          "N/A"
        ])
        
        :ok = Mosaic.DB.execute(state.conn, "INSERT INTO vec_chunks (id, embedding) VALUES (?, ?)", [
          id, 
          Jason.encode!(embedding)
        ])
        
        Mosaic.DB.execute(state.conn, "COMMIT")
        new_count = state.count + 1
        {:reply, :ok, %{state | count: new_count}}
      rescue
        e ->
          Mosaic.DB.execute(state.conn, "ROLLBACK")
          Logger.error("Failed to insert into cell #{state.path}: #{inspect(e)}")
          {:reply, {:error, e}, state}
      end
    end
  end

  def handle_call({:search, query_embedding, limit}, _from, state) do
    embedding_json = Jason.encode!(query_embedding)
    # Using sqlite-vec for similarity search
    case Mosaic.DB.query(state.conn, """
      SELECT d.id, d.metadata, vec_distance(vc.embedding, ?) AS similarity
      FROM documents d
      JOIN vec_chunks vc ON d.id = vc.id
      ORDER BY similarity ASC
      LIMIT ?
    """, [embedding_json, limit]) do
      {:ok, rows} ->
        results = Enum.map(rows, fn [id, metadata_json, similarity] ->
          %{id: id, metadata: Jason.decode!(metadata_json), similarity: 1 - similarity, cell_path: state.path} # Convert distance to similarity
        end)
        {:reply, {:ok, results}, state}
      {:error, e} ->
        Logger.error("Error searching cell #{state.path}: #{inspect(e)}")
        {:reply, {:error, e}, state}
    end
  end

  def handle_call(:get_info, _from, state) do
    {:reply, %{path: state.path, count: state.count, capacity: state.capacity}, state}
  end

  defp create_schema(conn) do
    # These tables are simplified compared to main Mosaic DB as cells only store embeddings
    Mosaic.DB.execute(conn, """
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        text TEXT,
        metadata TEXT
      );
    """)
    Mosaic.DB.execute(conn, """
      CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        doc_id TEXT,
        level TEXT,
        text TEXT
      );
    """)
    Mosaic.DB.execute(conn, """
      CREATE TABLE IF NOT EXISTS vec_chunks (
        id TEXT PRIMARY KEY,
        embedding BLOB
      );
    """)
  end

  defp via_tuple(cell_path) do
    {:global, {:mosaic_quantized_cell, cell_path}}
  end
end

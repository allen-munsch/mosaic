defmodule Mosaic.StorageManager do
  use GenServer
  require Logger



  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def init(nil), do: {:ok, %{}}


  def create_shard(path), do: GenServer.call(__MODULE__, {:create_shard, path})
  def open_shard(path), do: GenServer.call(__MODULE__, {:open_shard, path})
  def get_shard_doc_count(path), do: GenServer.call(__MODULE__, {:get_shard_doc_count, path})
  def archive_shard(path), do: GenServer.call(__MODULE__, {:archive_shard, path})
  def handle_call({:create_shard, path}, _from, state) do
    Logger.warning(">>> create_shard called with path: #{path}")
    try do
      File.mkdir_p!(Path.dirname(path))
      Logger.debug("Creating shard at #{path}, dir exists: #{File.dir?(Path.dirname(path))}")
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      Logger.debug("Opened new db at #{path}")
      Exqlite.Sqlite3.enable_load_extension(conn, true)
      load_vec_extension(conn)
      :ok = create_base_schema(conn)
      :ok = ensure_vector_table(conn)
      Exqlite.Sqlite3.close(conn)
      Logger.debug("Created shard at #{path}, exists: #{File.exists?(path)}")
      {:reply, {:ok, path}, state}
    rescue
      e ->
        Logger.error("Failed to create shard at #{path}: #{inspect(e)}")
        {:reply, {:error, e}, state}
    end
  end

  def handle_call({:open_shard, path}, _from, state) do
    case Mosaic.ConnectionPool.checkout(path) do
      {:ok, conn} -> {:reply, {:ok, conn}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get_shard_doc_count, path}, _from, state) do
    case Mosaic.ConnectionPool.checkout(path) do
      {:ok, conn} ->
        count = query_scalar(conn, "SELECT COUNT(*) FROM documents;")
        Mosaic.ConnectionPool.checkin(path, conn)
        {:reply, {:ok, count}, state}
      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:archive_shard, path}, _from, state) do
    Logger.warning("Archiving shard at #{path} not implemented")
    {:reply, :ok, state}
  end

defp query_scalar(conn, sql) do
  {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
  {:row, [val]} = Exqlite.Sqlite3.step(conn, stmt)
  Exqlite.Sqlite3.release(conn, stmt)
  if is_binary(val), do: String.to_integer(val), else: val
end

defp create_base_schema(conn) do
  # Source documents (raw text only)
  Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS documents (
      id TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      metadata JSON,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );
  """)

  # Hierarchical chunks with provenance
  Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS chunks (
      id TEXT PRIMARY KEY,
      doc_id TEXT NOT NULL,
      parent_id TEXT,
      level TEXT NOT NULL,
      text TEXT NOT NULL,
      start_offset INTEGER NOT NULL,
      end_offset INTEGER NOT NULL,
      pagerank REAL DEFAULT 0.0,
      FOREIGN KEY (doc_id) REFERENCES documents(id) ON DELETE CASCADE
    );
  """)

  Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);")
  Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_chunks_parent ON chunks(parent_id);")
  Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_chunks_level ON chunks(level);")
  Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_chunks_doc_level ON chunks(doc_id, level);")
  :ok
end

defp ensure_vector_table(conn) do
  embedding_dim = Mosaic.Config.get(:embedding_dim)

  create_vec_table = """
  CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
    id TEXT PRIMARY KEY,
    embedding float[#{embedding_dim}]
  );
  """

  case Exqlite.Sqlite3.execute(conn, create_vec_table) do
    :ok ->
      Logger.debug("Created vec_chunks using vec0")
      :ok

    {:error, reason} ->
      Logger.error("""
      Failed to create vec_chunks using vec0 extension.
      The SQLite vec extension appears to be missing or not loaded.
      Reason: #{inspect(reason)}
      """)

      raise """
      SQLite vec extension (`vec0`) not loaded. Cannot continue.
      """
  end
end

defp sqlite_vec_path do
  System.get_env("SQLITE_VEC_PATH") ||
    "deps/sqlite_vec/priv/0.1.5/vec0.so"
end

def load_vec_extension(conn) do
  ext_path = sqlite_vec_path()
  absolute_ext_path = Path.expand(ext_path, File.cwd!())

  unless File.exists?(absolute_ext_path) do
    raise "sqlite-vec extension not found at #{absolute_ext_path}"
  else
    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT load_extension(?)")
      :ok = Exqlite.Sqlite3.bind(stmt, [absolute_ext_path])
      Exqlite.Sqlite3.step(conn, stmt)
      Exqlite.Sqlite3.release(conn, stmt)

      Logger.debug("Loaded sqlite-vec extension from #{absolute_ext_path}")

      case verify_vec0_available(conn) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "sqlite-vec loaded but vec0 not available: #{inspect(reason)}"
      end
    rescue
      e ->
        raise "Failed to load sqlite-vec extension: #{inspect(e)}"
    end
  end
end

defp verify_vec0_available(conn) do
  # Option A: Try creating a temporary virtual table
  test_result = Exqlite.Sqlite3.execute(conn, "CREATE VIRTUAL TABLE IF NOT EXISTS _vec_test USING vec0(test_id TEXT PRIMARY KEY, test_vec float[3])")
  case test_result do
    :ok ->
      Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS _vec_test")
      :ok
    {:error, _} ->
      {:error, :vec0_not_available}
  end
end
end

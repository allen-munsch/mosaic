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
    try do
      File.mkdir_p!(Path.dirname(path))
      {:ok, conn} = Exqlite.Sqlite3.open(path)

      with :ok <- Exqlite.Sqlite3.enable_load_extension(conn, true),
           {:ok, ^conn} <- load_ext(conn, sqlite_vec_path()),
           :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;"),
           :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;"),
           :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size=-128000;"),
           :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;"),
           :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size=268435456;"),
           :ok <- create_schema(conn) do
        :ok = Exqlite.Sqlite3.close(conn)
        Logger.info("Successfully created shard at #{path}")
        {:reply, {:ok, path}, state}
      else
        {:error, reason} ->
          Logger.error("Failed to create shard at #{path} due to extension load or schema error: #{inspect(reason)}")
          Exqlite.Sqlite3.close(conn) # Ensure connection is closed on error
          {:reply, {:error, reason}, state}
        _ -> # Catch any other errors from execute/2
          Logger.error("Failed to create shard at #{path} due to unexpected error.")
          Exqlite.Sqlite3.close(conn)
          {:reply, {:error, :unexpected_error}, state}
      end
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

  defp load_ext(conn, ext_path) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, "SELECT load_extension(?)"),
        :ok      <- Exqlite.Sqlite3.bind(stmt, [ext_path]),
        result   <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
      case result do
        {:row, _} -> {:ok, conn}
        :done -> {:ok, conn}
        _ ->
          Logger.error("Failed to load SQLite extension '#{ext_path}': #{inspect(result)}")
          {:error, :extension_load_failed}
      end
    else
      {:error, err} ->
        Logger.error("Error preparing or binding SQLite extension load statement: #{inspect(err)}")
        {:error, :extension_load_failed}
    end
  end

  defp query_scalar(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    {:row, [val]} = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    if is_binary(val), do: String.to_integer(val), else: val
  end

  defp sqlite_vec_path do
    System.get_env("SQLITE_VEC_PATH") || find_sqlite_vec()
  end

  defp find_sqlite_vec do
    case Path.wildcard("deps/sqlite_vec/priv/**/vec0.so") do
      [path | _] -> String.trim_trailing(path, ".so")
      [] -> "deps/sqlite_vec/priv/vec0"
    end
  end

  defp create_schema(conn) do
    # Documents table with embedding stored inline
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        metadata JSON,
        embedding BLOB,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        pagerank REAL DEFAULT 0.0
      );
    """)

    Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_docs_created ON documents(created_at);")
    Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_docs_pagerank ON documents(pagerank DESC);")

    # Vector index using sqlite-vec
    embedding_dim = Mosaic.Config.get(:embedding_dim)
    Exqlite.Sqlite3.execute(conn, "CREATE VIRTUAL TABLE IF NOT EXISTS vec_documents USING vec0(id TEXT PRIMARY KEY, embedding float[#{embedding_dim}]);")
  end
end

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

      :ok = Exqlite.Sqlite3.enable_load_extension(conn, true)
      load_ext(conn, SqliteVss.loadable_path_vector0())
      load_ext(conn, SqliteVss.loadable_path_vss0())

      Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
      Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;")
      Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size=-128000;")
      Exqlite.Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;")
      Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size=268435456;")

      create_schema(conn)
      :ok = Exqlite.Sqlite3.close(conn)

      Logger.info("Successfully created shard at #{path}")
      {:reply, {:ok, path}, state}
    rescue
      e ->
        Logger.error("Failed to create shard at #{path}: #{inspect(e)}")
        {:reply, {:error, e}, state}
    end
  end

  def handle_call({:open_shard, path}, _from, state) do
    case Mosaic.Resilience.checkout(path) do
      {:ok, conn} -> {:reply, {:ok, conn}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get_shard_doc_count, path}, _from, state) do
    case Mosaic.Resilience.checkout(path) do
      {:ok, conn} ->
        count = query_scalar(conn, "SELECT COUNT(*) FROM documents;")
        Mosaic.Resilience.checkin(path, conn)
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
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT load_extension(?)")
    :ok = Exqlite.Sqlite3.bind(stmt, [ext_path])
    Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end

  defp query_scalar(conn, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    {:row, [val]} = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    if is_binary(val), do: String.to_integer(val), else: val
  end

  defp create_schema(conn) do
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, text TEXT NOT NULL, metadata TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP);")
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS vectors (id TEXT PRIMARY KEY, vec BLOB NOT NULL, FOREIGN KEY (id) REFERENCES documents(id) ON DELETE CASCADE);")
    embedding_dim = Mosaic.Config.get(:embedding_dim)
    Exqlite.Sqlite3.execute(conn, "CREATE VIRTUAL TABLE IF NOT EXISTS vss_vectors using vss0(vec(#{embedding_dim}));")
  end
end

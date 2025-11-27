defmodule Mosaic.ConnectionPool do
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts), do: {:ok, %{connections: %{}, max_per_shard: 5}}

  def checkout(shard_path), do: GenServer.call(__MODULE__, {:checkout, shard_path})
  def checkin(shard_path, conn), do: GenServer.cast(__MODULE__, {:checkin, shard_path, conn})

  def handle_call({:checkout, shard_path}, _from, state) do
    case Map.get(state.connections, shard_path) do
      nil ->
        case open_with_extensions(shard_path) do
          {:ok, conn} -> {:reply, {:ok, conn}, state}
          error -> {:reply, error, state}
        end
      [conn | rest] ->
        new_conns = Map.put(state.connections, shard_path, rest)
        {:reply, {:ok, conn}, %{state | connections: new_conns}}
    end
  end

  def handle_cast({:checkin, shard_path, conn}, state) do
    current = Map.get(state.connections, shard_path, [])
    new_conns = if length(current) < state.max_per_shard do
      Map.put(state.connections, shard_path, [conn | current])
    else
      Exqlite.Sqlite3.close(conn)
      state.connections
    end
    {:noreply, %{state | connections: new_conns}}
  end

  defp open_with_extensions(shard_path) do
    case Exqlite.Sqlite3.open(shard_path) do
      {:ok, conn} ->
        :ok = Exqlite.Sqlite3.enable_load_extension(conn, true)
        load_ext(conn, SqliteVss.loadable_path_vector0())
        load_ext(conn, SqliteVss.loadable_path_vss0())
        {:ok, conn}
      error -> error
    end
  rescue
    e -> {:error, e}
  end

  defp load_ext(conn, ext_path) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT load_extension(?)")
    :ok = Exqlite.Sqlite3.bind(stmt, [ext_path])
    Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
  end
end

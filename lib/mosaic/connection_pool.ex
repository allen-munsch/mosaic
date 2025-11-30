defmodule Mosaic.ConnectionPool do
  use GenServer
  require Logger

  @moduledoc """
  This module manages a pool of SQLite connections for each shard,
  providing features like health checks, automatic reconnection, and WAL checkpoint management.
  """

  defstruct [:pools, :config]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(opts) do
    config = %{
      max_per_shard: Keyword.get(opts, :max_per_shard, 5),
      busy_timeout: Keyword.get(opts, :busy_timeout, 5000),
      wal_autocheckpoint: Keyword.get(opts, :wal_autocheckpoint, 1000),
      journal_size_limit: Keyword.get(opts, :journal_size_limit, 67108864)
    }
    {:ok, %__MODULE__{pools: %{}, config: config}}
  end

  def checkout(shard_path), do: GenServer.call(__MODULE__, {:checkout, shard_path})
  def checkin(shard_path, conn), do: GenServer.cast(__MODULE__, {:checkin, shard_path, conn})

  def handle_call({:checkout, shard_path}, _from, state) do
    pool = Map.get(state.pools, shard_path, [])
    max_per_shard = state.config.max_per_shard

    do_checkout(shard_path, pool, max_per_shard, state)
  end

  defp do_checkout(shard_path, pool, max_per_shard, state) do
    case pool do
      [] ->
        case open_with_extensions(shard_path, state.config) do
          {:ok, conn} -> {:reply, {:ok, conn}, state}
          error -> {:reply, error, state}
        end
      [conn | rest] ->
        if connection_healthy?(conn) do
          new_pools = Map.put(state.pools, shard_path, rest)
          {:reply, {:ok, conn}, %{state | pools: new_pools}}
        else
          Exqlite.Sqlite3.close(conn)
          do_checkout(shard_path, rest, max_per_shard, state) # Retry with remaining connections
        end
    end
  end

  def handle_cast({:checkin, shard_path, conn}, state) do
    current_pool = Map.get(state.pools, shard_path, [])
    max_per_shard = state.config.max_per_shard

    new_pools = if length(current_pool) < max_per_shard do
      Map.put(state.pools, shard_path, [conn | current_pool])
    else
      Exqlite.Sqlite3.close(conn)
      state.pools
    end
    {:noreply, %{state | pools: new_pools}}
  end

  defp connection_healthy?(conn) do
    case Exqlite.Sqlite3.execute(conn, "SELECT 1") do
      :ok -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp open_with_extensions(shard_path, config) do
    case Exqlite.Sqlite3.open(shard_path) do
      {:ok, conn} ->
        :ok = Exqlite.Sqlite3.enable_load_extension(conn, true)
        load_ext(conn, sqlite_vec_path())

        # Apply pragmas
        Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = #{config.busy_timeout};")
        Exqlite.Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint = #{config.wal_autocheckpoint};")
        Exqlite.Sqlite3.execute(conn, "PRAGMA journal_size_limit = #{config.journal_size_limit};")

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

  defp sqlite_vec_path do
    System.get_env("SQLITE_VEC_PATH") || "deps/sqlite_vec/priv/0.1.5/vec0"
  end
end

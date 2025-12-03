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
    Logger.debug("Checkout called with: #{inspect(shard_path)}")
    pool = Map.get(state.pools, shard_path, [])
    max_per_shard = state.config.max_per_shard

    do_checkout(shard_path, pool, max_per_shard, state)
  end

  defp do_checkout(shard_path, pool, max_per_shard, state) do
    case pool do
      [] ->
        case open_with_extensions(shard_path, state.config) do
          {:ok, conn} -> {:reply, {:ok, conn}, state}
          {:error, reason} = error ->
            Logger.error("Failed to open #{shard_path}: #{inspect(reason)}")
            {:reply, error, state}
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
    unless File.exists?(shard_path) do
      Logger.error("File does not exist: #{shard_path}")
      {:error, {:file_not_found, shard_path}}
    else
      case Exqlite.Sqlite3.open(shard_path) do
        {:ok, conn} ->
          try do
            Exqlite.Sqlite3.enable_load_extension(conn, true)
            Mosaic.StorageManager.load_vec_extension(conn)
            Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = #{config.busy_timeout};")
            Exqlite.Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint = #{config.wal_autocheckpoint};")
            Exqlite.Sqlite3.execute(conn, "PRAGMA journal_size_limit = #{config.journal_size_limit};")
            {:ok, conn}
          rescue
            e ->
              Logger.error("Extension loading failed: #{inspect(e)}")
              Exqlite.Sqlite3.close(conn)
              {:error, {:extension_failed, e}}
          end
        {:error, reason} ->
          Logger.error("SQLite open failed for #{shard_path}: #{inspect(reason)}")
          {:error, {:open_failed, reason}}
      end
    end
  end
end

defmodule Mosaic.Resilience do
  use GenServer
  require Logger

  @moduledoc """
  This module provides common resilience strategies such as circuit breaking
  and connection pooling.
  """

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts), do: {:ok, %{connections: %{}, max_per_shard: 5}}

  def checkout(shard_path), do: GenServer.call(__MODULE__, {:checkout, shard_path})
  def checkin(shard_path, conn), do: GenServer.cast(__MODULE__, {:checkin, shard_path, conn})

  def handle_call({:checkout, shard_path}, _from, state) do
    case Map.get(state.connections, shard_path, []) do
      [] -> create_new_connection(shard_path, state)
      [conn | rest] ->
        if connection_healthy?(conn) do
          {:reply, {:ok, conn}, %{state | connections: Map.put(state.connections, shard_path, rest)}}
        else
          Exqlite.Sqlite3.close(conn)
          # Recursively call handle_call to try getting another connection (or creating a new one)
          handle_call({:checkout, shard_path}, nil, %{state | connections: Map.put(state.connections, shard_path, rest)})
        end
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

  defp connection_healthy?(conn) do
    case Exqlite.Sqlite3.execute(conn, "SELECT 1") do
      :ok -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp create_new_connection(shard_path, state) do
    case open_with_extensions(shard_path) do
      {:ok, conn} -> {:reply, {:ok, conn}, state}
      error -> {:reply, error, state}
    end
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
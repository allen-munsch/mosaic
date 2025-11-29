defmodule Mosaic.FederatedQuery do
  @moduledoc "Execute SQL across all shards with fan-out/fan-in"
  require Logger

  def execute(sql, params \\ [], opts \\ []) do
    shards = list_all_shards()
    timeout = Keyword.get(opts, :timeout, 30_000)
    
    shards
    |> Task.async_stream(fn shard -> execute_on_shard(shard, sql, params) end, timeout: timeout, on_timeout: :kill_task)
    |> Enum.flat_map(fn
      {:ok, {:ok, rows}} -> rows
      {:ok, {:error, reason}} -> 
        Logger.warning("Shard query failed: #{inspect(reason)}")
        []
      {:exit, :timeout} -> []
    end)
  end

  def execute_with_metadata(sql, params \\ [], opts \\ []) do
    shards = list_all_shards()
    timeout = Keyword.get(opts, :timeout, 30_000)
    
    shards
    |> Task.async_stream(fn shard -> {shard.id, execute_on_shard(shard, sql, params)} end, timeout: timeout)
    |> Enum.map(fn
      {:ok, {shard_id, {:ok, rows}}} -> %{shard_id: shard_id, rows: rows, status: :ok}
      {:ok, {shard_id, {:error, reason}}} -> %{shard_id: shard_id, rows: [], status: :error, reason: reason}
      {:exit, :timeout} -> %{shard_id: nil, rows: [], status: :timeout}
    end)
  end

  def aggregate(sql, params \\ [], agg_fn) do
    execute(sql, params) |> agg_fn.()
  end

  def count(table \\ "documents") do
    execute("SELECT count(*) FROM #{table}")
    |> Enum.map(fn [n] -> n end)
    |> Enum.sum()
  end

  defp execute_on_shard(shard, sql, params) do
    case Mosaic.Resilience.checkout(shard.path) do
      {:ok, conn} ->
        result = run_query(conn, sql, params)
        Mosaic.Resilience.checkin(shard.path, conn)
        result
      {:error, _} = err -> err
    end
  end

  defp run_query(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = fetch_all(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    {:ok, rows}
  rescue
    e -> {:error, e}
  end

  defp fetch_all(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, _} = err -> err
    end
  end

  defp list_all_shards do
    GenServer.call(Mosaic.ShardRouter, :list_all_shards)
  end
end

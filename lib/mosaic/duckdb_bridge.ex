defmodule Mosaic.DuckDBBridge do
  use GenServer
  require Logger

  defstruct [:db, :conn, :attached_shards]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    case Duckdbex.open(":memory:") do
      {:ok, db} ->
        {:ok, conn} = Duckdbex.connection(db)
        install_extensions(conn)
        {:ok, %__MODULE__{db: db, conn: conn, attached_shards: MapSet.new()}}
      {:error, reason} ->
        Logger.error("DuckDB init failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  def query(sql, params \\ []), do: GenServer.call(__MODULE__, {:query, sql, params}, 60_000)
def refresh_shards, do: GenServer.call(__MODULE__, :refresh_shards, 30_000)
def attached_shards, do: GenServer.call(__MODULE__, :list_shards)

def handle_call({:query, sql, params}, _from, state) do
    state = ensure_shards_attached(state)
    result = execute_federated(sql, params, state.conn)
    {:reply, result, state}
  end

def handle_call(:refresh_shards, _from, state) do
    {:reply, :ok, attach_all_shards(state)}
  end

def handle_call(:list_shards, _from, state) do
    {:reply, MapSet.to_list(state.attached_shards), state}
  end

defp install_extensions(conn) do
    Duckdbex.query(conn, "INSTALL sqlite_scanner;")
    Duckdbex.query(conn, "LOAD sqlite_scanner;")
    Duckdbex.query(conn, "SET threads TO 4;")
  end

defp ensure_shards_attached(state) do
    current = list_current_shards()
    new_shards = MapSet.difference(MapSet.new(current), state.attached_shards)
    if MapSet.size(new_shards) > 0 do
      attach_shards(state.conn, MapSet.to_list(new_shards))
      %{state | attached_shards: MapSet.union(state.attached_shards, new_shards)}
    else
      state
    end
  end

defp attach_all_shards(state) do
    shards = list_current_shards()
    detach_all(state.conn)
    attach_shards(state.conn, shards)
    %{state | attached_shards: MapSet.new(shards)}
  end

defp list_current_shards do
    try do
      Mosaic.ShardRouter.list_all_shards()
    catch
      :exit, _ -> []
    end
  end

defp attach_shards(conn, shards) do
    Enum.with_index(shards)
    |> Enum.each(fn {shard, idx} ->
      alias_name = "shard_#{idx}"
      Duckdbex.query(conn, "DETACH DATABASE IF EXISTS #{alias_name};")
      Duckdbex.query(conn, "ATTACH '#{shard.path}' AS #{alias_name} (TYPE sqlite, READ_ONLY);")
    end)
  end

defp detach_all(conn) do
    case Duckdbex.query(conn, "SELECT name FROM duckdb_databases() WHERE name != 'memory'") do
      {:ok, result} ->
        case Duckdbex.fetch_all(result) do
          {:ok, rows} -> Enum.each(rows, fn [name] -> Duckdbex.query(conn, "DETACH DATABASE #{name}") end)
          _ -> :ok
        end
      _ -> :ok
    end
  end

defp execute_federated(sql, params, conn) do
    shards = list_current_shards()
    if Enum.empty?(shards) do
      {:ok, []}
    else
      federated_sql = rewrite_to_federated(sql, shards)
      case Duckdbex.query(conn, federated_sql, params) do
        {:ok, result} ->
          case Duckdbex.fetch_all(result) do
            {:ok, rows} -> {:ok, rows}
            {:error, err} -> {:error, err}
          end
        {:error, err} -> {:error, err}
      end
    end
  end

defp rewrite_to_federated(sql, shards) do
    if Regex.match?(~r/FROM\s+documents\b/i, sql) do
      shard_queries = Enum.with_index(shards)
      |> Enum.map(fn {_, idx} ->
        sql
        |> String.replace(~r/FROM\s+documents\b/i, "FROM shard_#{idx}.documents")
        |> String.replace(~r/ORDER\s+BY\s+[^;]+?(LIMIT|$)/i, "")
        |> String.replace(~r/LIMIT\s+\d+/i, "")
        |> String.trim()
      end)
      |> Enum.join("\nUNION ALL\n")

      order_clause = case Regex.run(~r/(ORDER\s+BY\s+[^;]+?)(?=LIMIT|$)/i, sql) do
        [_, clause] -> clause
        nil -> ""
      end

      limit_clause = case Regex.run(~r/(LIMIT\s+\d+)/i, sql) do
        [_, clause] -> clause
        nil -> ""
      end

      "WITH federated AS (#{shard_queries}) SELECT * FROM federated #{order_clause} #{limit_clause}"
    else
      sql
    end
  end
end
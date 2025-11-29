defmodule Mosaic.PageRankComputer do
  use GenServer
  require Logger

  @compute_interval :timer.hours(24)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    schedule_compute()
    {:ok, %{}}
  end

  def handle_info(:compute, state) do
    compute_pagerank()
    schedule_compute()
    {:noreply, state}
  end

  defp schedule_compute, do: Process.send_after(self(), :compute, @compute_interval)

  defp compute_pagerank do
    shards = GenServer.call(Mosaic.ShardRouter, :list_all_shards)
    Enum.each(shards, &compute_shard_pagerank/1)
  end

  defp compute_shard_pagerank(shard) do
    case Mosaic.Resilience.checkout(shard.path) do
      {:ok, conn} ->
        Exqlite.Sqlite3.execute(conn, "ALTER TABLE documents ADD COLUMN pagerank REAL DEFAULT 0.0")
        Exqlite.Sqlite3.execute(conn, "UPDATE documents SET pagerank = 1.0")
        Mosaic.Resilience.checkin(shard.path, conn)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end

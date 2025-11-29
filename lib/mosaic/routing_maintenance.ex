defmodule Mosaic.RoutingMaintenance do
  use GenServer
  require Logger

  @refresh_interval :timer.hours(1)
  @sample_size 100

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    schedule_refresh()
    {:ok, %{}}
  end

  def handle_info(:refresh_centroids, state) do
    refresh_all_centroids()
    schedule_refresh()
    {:noreply, state}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh_centroids, @refresh_interval)

  defp refresh_all_centroids do
    shards = GenServer.call(Mosaic.ShardRouter, :list_all_shards)
    Enum.each(shards, &refresh_centroid/1)
  end

  defp refresh_centroid(shard) do
    case sample_embeddings(shard.path, @sample_size) do
      [] -> :ok
      embeddings ->
        centroid = compute_centroid(embeddings)
        GenServer.cast(Mosaic.ShardRouter, {:update_centroid, shard.id, centroid})
    end
  end

  defp sample_embeddings(path, limit) do
    case Mosaic.Resilience.checkout(path) do # Changed from Mosaic.ConnectionPool.checkout
      {:ok, conn} ->
        {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT vec FROM vss_vectors ORDER BY RANDOM() LIMIT ?")
        Exqlite.Sqlite3.bind(stmt, [limit])
        result = fetch_vectors(conn, stmt)
        Mosaic.Resilience.checkin(path, conn) # Changed from Mosaic.ConnectionPool.checkin
        result
      _ -> []
    end
  end

  defp fetch_vectors(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [vec]} -> fetch_vectors(conn, stmt, [Jason.decode!(vec) | acc])
      :done -> acc
    end
  end

  defp compute_centroid(embeddings) do
    dim = length(hd(embeddings))
    count = length(embeddings)
    embeddings
    |> Enum.reduce(List.duplicate(0.0, dim), fn emb, acc ->
      Enum.zip(emb, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / count))
  end
end

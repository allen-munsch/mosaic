defmodule Mosaic.HealthCheck do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_health_check()
    {:ok, %{last_check: nil, status: :healthy}}
  end

  def handle_info(:check_health, state) do
    health_status = perform_health_check()

    Logger.info("Heartbeat: health check completed, status: #{health_status.status}")

    schedule_health_check()
    {:noreply, %{state | last_check: DateTime.utc_now(), status: health_status.status}}
  end

  defp schedule_health_check do
    Process.send_after(self(), :check_health, 10_000)  # Every 10 seconds
  end

  defp perform_health_check do
    checks = [
      check_router_health(),
      check_embedding_service(),
      check_storage(),
      check_memory()
    ]

    failed = Enum.filter(checks, fn {_name, status} -> status != :ok end)

    %{
      timestamp: DateTime.utc_now(),
      status: if(length(failed) == 0, do: :healthy, else: :degraded),
      checks: Map.new(checks),
      failed_checks: Enum.map(failed, fn {name, _} -> name end)
    }
  end

  defp check_router_health do
    try do
      # Try a simple routing operation
      test_vector = List.duplicate(0.1, Mosaic.Config.get(:embedding_dim))
      Mosaic.ShardRouter.find_similar_shards_sync(test_vector, 1, [use_cache: true])
      {:router, :ok}
    rescue
      _ -> {:router, :failed}
    end
  end

  defp check_embedding_service do
    try do
      task = Task.async(fn -> Nx.Serving.batched_run(MosaicEmbedding, "test") end)
      case Task.yield(task, 2000) || Task.shutdown(task) do
        {:ok, _} -> {:embeddings, :ok}
        nil -> {:embeddings, :timeout}
      end
    rescue
      _ -> {:embeddings, :failed}
    end
  end

  defp check_storage do
    storage_path = Mosaic.Config.get(:storage_path)

    case File.stat(storage_path) do
      {:ok, %{access: access}} when access in [:read, :read_write] ->
        {:storage, :ok}
      _ ->
        {:storage, :failed}
    end
  end

  defp check_memory do
    memory = :erlang.memory()
    total_mb = memory[:total] / 1_024 / 1_024

    if total_mb < 8_000 do  # Less than 8GB
      {:memory, :ok}
    else
      {:memory, :warning}
    end
  end
end

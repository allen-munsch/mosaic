defmodule Mosaic.ShardSync do
  @moduledoc """
  Syncs SQLite shards between local storage and remote storage backend.

  Handles:
    * Pulling shards from remote on startup
    * Pushing new/changed shards to remote periodically
    * Push all shards on shutdown

  ## Configuration

      config :mosaic,
        shard_sync_enabled: true,
        shard_sync_interval_ms: 60_000   # push every 60s
  """

  use GenServer

  require Logger

  @type shard_path :: String.t()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Logger.info("ShardSync: pulling shards from remote on startup...")
      pull_all()
      schedule_push()
    end

    {:ok, %{last_push: nil}}
  end

  @impl true
  def handle_info(:push_shards, state) do
    if enabled?() do
      push_all()
      schedule_push()
    end
    {:noreply, %{state | last_push: DateTime.utc_now()}}
  end

  # ── Public API ────────────────────────────────────────────

  @doc "Push a single shard to remote storage."
  @spec push_shard(shard_path()) :: :ok | {:error, term()}
  def push_shard(local_path) do
    if enabled?() do
      key = shard_key(local_path)
      backend().put(key, local_path)
    else
      :ok
    end
  end

  @doc "Pull a single shard from remote storage."
  @spec pull_shard(shard_path()) :: :ok | {:error, term()}
  def pull_shard(local_path) do
    if enabled?() do
      key = shard_key(local_path)
      backend().get(key, local_path)
    else
      {:error, :sync_disabled}
    end
  end

  @doc "Push all local shards to remote storage."
  def push_all do
    if enabled?() do
      storage_path = Mosaic.Config.get(:storage_path)
      backend = backend()

      if File.dir?(storage_path) do
        Path.wildcard(Path.join(storage_path, "**/*.db"))
        |> Enum.each(fn path ->
          key = shard_key(path)
          case backend.put(key, path) do
            :ok -> Logger.debug("ShardSync: pushed #{key}")
            {:error, reason} -> Logger.error("ShardSync: failed to push #{key}: #{inspect(reason)}")
          end
        end)
      end
    end

    :ok
  end

  @doc "Pull all shards from remote storage to local."
  def pull_all do
    if enabled?() do
      backend = backend()

      case backend.list("") do
        {:ok, keys} ->
          Enum.each(keys, fn key ->
            local_path = local_path(key)

            unless File.exists?(local_path) do
              case backend.get(key, local_path) do
                :ok -> Logger.info("ShardSync: pulled #{key}")
                {:error, reason} -> Logger.error("ShardSync: failed to pull #{key}: #{inspect(reason)}")
              end
            end
          end)

        {:error, reason} ->
          Logger.error("ShardSync: failed to list shards: #{inspect(reason)}")
      end
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────

  defp backend, do: Mosaic.StorageBackend.get()

  defp enabled?, do: Mosaic.Config.get(:shard_sync_enabled, false)

  defp shard_key(local_path) do
    storage_path = Mosaic.Config.get(:storage_path)
    Path.relative_to(local_path, storage_path)
  end

  defp local_path(key) do
    storage_path = Mosaic.Config.get(:storage_path)
    Path.join(storage_path, key)
  end

  defp schedule_push do
    interval = Mosaic.Config.get(:shard_sync_interval_ms, 60_000)
    Process.send_after(self(), :push_shards, interval)
  end
end

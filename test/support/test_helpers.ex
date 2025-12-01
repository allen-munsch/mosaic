defmodule Mosaic.TestHelpers do
  alias Mosaic.{
    StorageManager,
    ConnectionPool,
    ShardRouter,
    EmbeddingCache,
    Indexer,
    QueryEngine,
    Cache.ETS # Add ETS cache
  }

  def setup_integration_test(_context \\ %{}) do
    temp_dir = Path.join(System.tmp_dir!(), "mosaic_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    
    # Set test config
    Application.put_env(:mosaic, :storage_path, Path.join(temp_dir, "shards"))
    Application.put_env(:mosaic, :routing_db_path, Path.join(temp_dir, "routing/index.db"))
    Application.put_env(:mosaic, :embedding_dim, 384)
    Application.put_env(:mosaic, :min_similarity, 0.1)
    
    File.mkdir_p!(Application.get_env(:mosaic, :storage_path))
    File.mkdir_p!(Path.dirname(Application.get_env(:mosaic, :routing_db_path)))

    start_services()

    on_exit_fn = fn ->
      stop_services()
      File.rm_rf!(temp_dir)
      # No need to stop_services here, the app's supervisor handles it on teardown.
    end
    {:ok, on_exit: on_exit_fn}
  end

  def start_services do
    services = [
      ETS, # Start ETS cache
      StorageManager,
      ConnectionPool,
      ShardRouter,
      EmbeddingCache,
      Indexer,
      QueryEngine
    ]
    for service <- services do
      if Process.whereis(service) do
        try do
          GenServer.stop(service, :normal, :infinity)
        rescue
          _ -> :ok # Ignore if already stopped
        end
      end
      {:ok, _} = service.start_link([])
    end
    ShardRouter.reset_state()
  end

  def stop_services do
    services = [
      QueryEngine,
      Indexer,
      EmbeddingCache,
      ShardRouter,
      ConnectionPool,
      StorageManager,
      ETS # Stop ETS cache
    ]
    for service <- services do
      if Process.whereis(service) do
        try do
          GenServer.stop(service, :normal, :infinity)
        rescue
          _ -> :ok # Ignore if already stopped
        end
      end
    end
  end
end

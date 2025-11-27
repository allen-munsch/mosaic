defmodule Mosaic.Config do
  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def get_all(), do: GenServer.call(__MODULE__, :get_all)
  def update_setting(key, value), do: GenServer.call(__MODULE__, {:update_setting, key, value})
  def get(key, pid_or_name), do: GenServer.call(pid_or_name, {:get, key})
  def get_all(pid_or_name), do: GenServer.call(pid_or_name, :get_all)

  def init(_opts) do
    config = %{
      storage_path: System.get_env("STORAGE_PATH") || "/tmp/mosaic/shards",
      routing_db_path: System.get_env("ROUTING_DB_PATH") || "/tmp/mosaic/routing/index.db",
      cache_path: System.get_env("CACHE_PATH") || "/tmp/mosaic/cache",
      embedding_model: System.get_env("EMBEDDING_MODEL") || "local",
      embedding_dim: parse_int(System.get_env("EMBEDDING_DIM"), 384),
      embedding_batch_size: parse_int(System.get_env("EMBEDDING_BATCH_SIZE"), 32),
      embedding_batch_timeout_ms: parse_int(System.get_env("EMBEDDING_BATCH_TIMEOUT_MS"), 100),
      openai_api_key: System.get_env("OPENAI_API_KEY"),
      huggingface_api_key: System.get_env("HUGGINGFACE_API_KEY"),
      embedding_cache_max_size: parse_int(System.get_env("EMBEDDING_CACHE_MAX_SIZE"), 100000),
      shard_size: parse_int(System.get_env("SHARD_SIZE"), 10000),
      shard_depth: parse_int(System.get_env("SHARD_DEPTH"), 3),
      default_shard_limit: parse_int(System.get_env("DEFAULT_SHARD_LIMIT"), 50),
      default_result_limit: parse_int(System.get_env("DEFAULT_RESULT_LIMIT"), 20),
      query_timeout: parse_int(System.get_env("QUERY_TIMEOUT"), 10000),
      query_cache_ttl_seconds: parse_int(System.get_env("QUERY_CACHE_TTL_SECONDS"), 300),
      redis_url: System.get_env("REDIS_URL") || "redis://localhost:6379/1",
      routing_cache_size: parse_int(System.get_env("ROUTING_CACHE_SIZE"), 10000),
      routing_cache_max_size: parse_int(System.get_env("ROUTING_CACHE_MAX_SIZE"), 10000),
      routing_cache_refresh_interval_ms: parse_int(System.get_env("ROUTING_CACHE_REFRESH_INTERVAL_MS"), 60000),
      min_similarity: parse_float(System.get_env("MIN_SIMILARITY"), 0.1),
      failure_threshold: parse_int(System.get_env("FAILURE_THRESHOLD"), 5),
      success_threshold: parse_int(System.get_env("SUCCESS_THRESHOLD"), 3),
      timeout_ms: parse_int(System.get_env("CIRCUIT_TIMEOUT_MS"), 60000),
      crawl_delay_ms: parse_int(System.get_env("CRAWL_DELAY_MS"), 1000),
      max_crawl_depth: parse_int(System.get_env("MAX_CRAWL_DEPTH"), 3),
      pagerank_iterations: parse_int(System.get_env("PAGERANK_ITERATIONS"), 10),
      pagerank_damping: parse_float(System.get_env("PAGERANK_DAMPING"), 0.85),
      pagerank_interval_hours: parse_int(System.get_env("PAGERANK_INTERVAL_HOURS"), 24)
    }
    File.mkdir_p!(config.storage_path)
    File.mkdir_p!(Path.dirname(config.routing_db_path))
    File.mkdir_p!(config.cache_path)
    {:ok, config}
  end

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
  def handle_call(:get_all, _from, state), do: {:reply, state, state}
  def handle_call({:update_setting, key, value}, _from, state) do
    new_state = Map.put(state, key, value)
    {:reply, :ok, new_state}
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(str, default) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default
  defp parse_float(str, default) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end
end
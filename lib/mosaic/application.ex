defmodule Mosaic.Application do
  use Application
  require Logger

  @moduledoc """
  MosaicDB: Federated Semantic Search + Analytics

  HOT PATH:  SQLite + sqlite-vec (search, < 50ms)
  WARM PATH: DuckDB (analytics, < 500ms)
  """

  def start(_type, _args) do
    if System.get_env("MOSAIC_QUIET") == "1" do
      Application.put_env(:mosaic, :startup_quiet, true)
      Logger.configure(level: :warning)
    end
    Logger.info("Starting MosaicDB")

    children = [
      # Cluster coordination (libcluster + :ra consensus)
      {Cluster.Supervisor, [topologies(), [name: Mosaic.ClusterSupervisor]]},

      # Storage layer
      {Mosaic.StorageManager, []},
      {Mosaic.ConnectionPool, []},

      # Remote storage sync (optional, enabled by config)
      {Mosaic.ShardSync, []},

      Mosaic.WorkerPool.child_spec(name: :router_pool, worker: Mosaic.ShardRouter.Worker, size: 10),

      # Cache (ETS or Redis based on config)
      cache_child_spec(),

      index_strategy_child_spec(),

      # Embeddings (configurable via MOSAIC_EMBEDDING_MODEL_NAME / embedding_model_name)
      {Mosaic.EmbeddingService, []},
      {Mosaic.EmbeddingCache, []},

      # Semantic result cache (intent-based, 10-100x query savings)
      # (standalone module, uses ETS + SQLite — no supervision needed)

      # HOT PATH: Query engine (SQLite + sqlite-vec)
      {Mosaic.QueryEngine, [
        cache: cache_module(),
        cache_ttl: Mosaic.Config.get(:query_cache_ttl_seconds),
        ranker: Mosaic.Ranking.Ranker.new(ranker_config()),
        index_strategy: Mosaic.Config.get(:index_strategy)
      ]},

      # WARM PATH: Analytics engine (DuckDB)
      {Mosaic.DuckDBBridge, []},

      # Crawling (optional)
      {Mosaic.CrawlerSupervisor, []},
      {Mosaic.URLFrontier, []},
      {Mosaic.CrawlerPipeline, []},

      # Background jobs
      {Mosaic.PageRankComputer, []},

      # Monitoring
      {Mosaic.Telemetry, []},
      {Mosaic.HealthCheck, []},

      # Evaluation harness (standalone module — uses SQLite, no supervision)

      # API
      {Plug.Cowboy, scheme: :http, plug: Mosaic.API, options: [port: port()]}
    ]

    children = if Mosaic.Config.get(:mcp_enabled) do
      children ++ [{Mosaic.MCP.Server, []}]
    else
      children
    end

    configure_nx_backend()

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Mosaic.Supervisor)

    # Deferred initialization — runs AFTER supervisor so ConnectionPool is available.
    # Run inline (not in Task) so tests and startup can rely on init completing.
    if Mosaic.Config.get(:auto_migrate, true) do
      run_pending_migrations()
    end

    # Ensure core database files exist before first use
    ensure_core_databases()

    if Mosaic.Config.get(:auth_enabled) or Mosaic.Config.get(:tenancy_enabled) do
      Mosaic.Auth.APIKey.init_auth_db()
      Mosaic.Tenancy.Isolator.init_system()
    end

    if Mosaic.Config.get(:consensus_enabled) do
      Mosaic.Consensus.Cluster.start_cluster()
    end

    # gRPC server (optional, port 4041)
    if Mosaic.Config.get(:grpc_enabled) do
      Mosaic.GRPCServer.start()
    end

    result
  end

  defp run_pending_migrations do
    storage_path = Mosaic.Config.get(:storage_path)
    if File.dir?(storage_path) do
      Path.wildcard(Path.join(storage_path, "*.db"))
      |> Enum.each(fn shard_path ->
        Mosaic.Migrations.apply(shard_path)
      end)
    end
  end

  defp ensure_core_databases do
    # Touch core DB files so they exist before first checkout.
    # Also ensure schema for each.
    db_specs = [
      {Mosaic.Memory.AgentMemory, :memory_db_path, :ensure_schema},
      {Mosaic.Pipelines.AgentPipeline, :pipeline_db_path, :ensure_schema},
    ]

    Enum.each(db_specs, fn {mod, path_fn, schema_fn} ->
      path = apply(mod, path_fn, [])
      if path do
        File.mkdir_p!(Path.dirname(path))
        unless File.exists?(path), do: File.write!(path, "")
        # Try to ensure schema (may fail if module not loaded)
        try do
          apply(mod, schema_fn, [])
        rescue
          _ -> :ok
        end
      end
    end)
  end

    defp configure_nx_backend do
    case Mosaic.Config.get(:nx_backend) do
      "exla" ->
        client = case Mosaic.Config.get(:nx_client) do
          "cuda" -> :cuda
          "host" -> :host
          _ -> :host
        end
        Nx.default_backend({EXLA.Backend, client: client})
      "binary" ->
        Nx.default_backend(Nx.BinaryBackend)
      _ ->
        Nx.default_backend(EXLA.Backend)
    end
  end

  defp cache_module do
    case Mosaic.Config.get(:cache_backend) do
      "redis" -> Mosaic.Cache.Redis
      _ -> Mosaic.Cache.ETS
    end
  end

  defp cache_child_spec do
    case cache_module() do
      Mosaic.Cache.Redis -> {Mosaic.Cache.Redis, [url: Mosaic.Config.get(:redis_url)]}
      Mosaic.Cache.ETS -> {Mosaic.Cache.ETS, [name: Mosaic.Cache.ETS]}
    end
  end

  defp ranker_config do
    [
      weights: %{
        vector_similarity: Mosaic.Config.get(:weight_vector),
        pagerank: Mosaic.Config.get(:weight_pagerank),
        freshness: Mosaic.Config.get(:weight_freshness),
        text_match: Mosaic.Config.get(:weight_text_match)
      },
      fusion: Mosaic.Config.get(:fusion_strategy) |> String.to_atom(),
      min_score: Mosaic.Config.get(:min_score)
    ]
  end

  defp topologies do
    [[semantic_fabric: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        secret: System.get_env("CLUSTER_SECRET", "mosaic-secret")
      ]
    ]]]
  end

  defp index_strategy_child_spec do
    strategy_name = Mosaic.Config.get(:index_strategy)
    strategy_module = case strategy_name do
      "binary" -> Mosaic.Index.Strategy.Binary
      "centroid" -> Mosaic.Index.Strategy.Centroid
      "hnsw" -> Mosaic.Index.Strategy.HNSW
      "ivf" -> Mosaic.Index.Strategy.IVF
      "pq" -> Mosaic.Index.Strategy.PQ
      "quantized" -> Mosaic.Index.Strategy.Quantized
      _ -> Mosaic.Index.Strategy.Binary
    end

    strategy_opts = get_strategy_opts(strategy_name)
    {Mosaic.Index.Supervisor, [strategy: strategy_module, opts: strategy_opts]}
  end

  defp get_strategy_opts("hnsw") do
    [m: Mosaic.Config.get(:hnsw_m), ef_construction: Mosaic.Config.get(:hnsw_ef_construction),
     ef_search: Mosaic.Config.get(:hnsw_ef_search), distance_fn: Mosaic.Config.get(:hnsw_distance_fn)]
  end
  defp get_strategy_opts("binary") do
    [bits: Mosaic.Config.get(:binary_bits), quantization: Mosaic.Config.get(:binary_quantization)]
  end
  defp get_strategy_opts("ivf") do
    [n_lists: Mosaic.Config.get(:ivf_n_lists), n_probe: Mosaic.Config.get(:ivf_n_probe)]
  end
  defp get_strategy_opts("pq") do
    [m: Mosaic.Config.get(:pq_m), k_sub: Mosaic.Config.get(:pq_k_sub)]
  end
  defp get_strategy_opts(_), do: []

  defp port do
    port_str = System.get_env("PORT") || to_string(Mosaic.Config.get(:http_port, 4040))
    String.to_integer(port_str)
  end
end

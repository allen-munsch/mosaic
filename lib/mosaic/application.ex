defmodule Mosaic.Application do
  use Application
  require Logger

  @moduledoc """
  MosaicDB: Federated Semantic Search + Analytics

  HOT PATH:  SQLite + sqlite-vec (search, < 50ms)
  WARM PATH: DuckDB (analytics, < 500ms)
  """

  def start(_type, _args) do
    Logger.info("Starting MosaicDB")
    {:ok, _} = Mosaic.Config.start_link()

    children = [
      # Cluster coordination
      {Cluster.Supervisor, [topologies(), [name: Mosaic.ClusterSupervisor]]},

      # Storage layer
      {Mosaic.StorageManager, []},
      {Mosaic.ConnectionPool, []},  # ADD THIS

      Mosaic.WorkerPool.child_spec(name: :router_pool, worker: Mosaic.ShardRouter.Worker, size: 10),

      # Cache (ETS or Redis based on config)
      cache_child_spec(),

      # Shard routing
      {Mosaic.ShardRouter, []},
      {Mosaic.BloomFilterManager, []},
      {Mosaic.RoutingMaintenance, []},

      # Embeddings
      {Mosaic.EmbeddingService, []},
      {Mosaic.EmbeddingCache, []},

      # HOT PATH: Query engine (SQLite + sqlite-vec)
      {Mosaic.QueryEngine, [
        cache: cache_module(),
        cache_ttl: Mosaic.Config.get(:query_cache_ttl_seconds),
        ranker: Mosaic.Ranking.Ranker.new(ranker_config())
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

      # API
      {Plug.Cowboy, scheme: :http, plug: Mosaic.API, options: [port: port()]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mosaic.Supervisor)
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

  defp port, do: System.get_env("PORT", "4040") |> String.to_integer()
end

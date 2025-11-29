defmodule Mosaic.Application do
  use Application
  require Logger

  @moduledoc """
  Enhanced Fractal SQLite Vector Semantic Fabric

  Key improvements:
  - Hierarchical shard routing with bloom filters
  - Adaptive batch sizing for embeddings
  - Connection pooling for SQLite operations
  - Smart caching with LRU eviction
  - Health monitoring and auto-recovery
  """

  def start(_type, _args) do
    Logger.info("Starting Mosaic: Enhanced Fractal SQLite Vector Semantic Fabric")

    # Manually start the config server first, as other child specs depend on it.
    {:ok, _} = Mosaic.Config.start_link()

    # The supervision tree dynamically starts the right cache backend
    # and injects it into the QueryEngine.
    children = children()

    opts = [strategy: :one_for_one, name: Mosaic.Supervisor]
    Logger.info("Starting supervisor with #{length(children)} children...")
    Supervisor.start_link(children, opts)
  end

  defp children do
    # Determine which cache implementation to use based on config.
    cache_impl = cache_module()
    ranker_opts = ranker_config()

    [
      # Core coordination
      {Cluster.Supervisor, [topologies(), [name: Mosaic.ClusterSupervisor]]},

      # Storage layer and configuration. Config is started manually above.
      {Mosaic.StorageManager, []},
      {Mosaic.ConnectionPool, []},

      # Start the selected cache implementation
      cache_child_spec(cache_impl),

      # Routing and indexing
      {Mosaic.ShardRouter, []},
      {Mosaic.BloomFilterManager, []},
      {Mosaic.RoutingMaintenance, []},

      # Embedding services
      {Mosaic.EmbeddingService, []},
      {Mosaic.EmbeddingCache, []},

      # Query execution with the cache and ranker implementations injected
      {Mosaic.QueryEngine,
       [
         cache: cache_impl,
         cache_ttl: Mosaic.Config.get(:query_cache_ttl_seconds),
         ranker: Mosaic.Ranking.Ranker.new(ranker_opts)
       ]},
      {Mosaic.CircuitBreaker, []},

      # Crawling pipeline
      {Mosaic.CrawlerSupervisor, []},
      {Mosaic.URLFrontier, []},
      {Mosaic.CrawlerPipeline, []},

      # PageRank computation
      {Mosaic.PageRankComputer, []},

      # Monitoring
      {Mosaic.Telemetry, []},
      {Mosaic.HealthCheck, []},

      # API
      {Plug.Cowboy, scheme: :http, plug: Mosaic.API, options: [port: get_port()]}
    ]
  end

  defp cache_module do
    case Mosaic.Config.get(:cache_backend) do
      "redis" -> Mosaic.Cache.Redis
      "ets" -> Mosaic.Cache.ETS
      _ -> Mosaic.Cache.ETS # Default to ETS
    end
  end

  # Returns the appropriate child spec for the chosen cache implementation.
  defp cache_child_spec(Mosaic.Cache.Redis) do
    {Mosaic.Cache.Redis, [url: Mosaic.Config.get(:redis_url)]}
  end

  defp cache_child_spec(Mosaic.Cache.ETS) do
    {Mosaic.Cache.ETS, [name: Mosaic.Cache.ETS]}
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
    [
      semantic_fabric: [
        strategy: Cluster.Strategy.Gossip,
        config: [
          port: 45892,
          if_addr: "0.0.0.0",
          multicast_addr: "230.1.1.251",
          multicast_ttl: 1,
          secret: System.get_env("CLUSTER_SECRET", "semantic-fabric-secret")
        ]
      ]
    ]
  end

  defp get_port do
    System.get_env("PORT", "4040") |> String.to_integer()
  end
end

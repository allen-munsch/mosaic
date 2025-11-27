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
    
    children = [
      # Core coordination
      {Cluster.Supervisor, [topologies(), [name: Mosaic.ClusterSupervisor]]},
      
      # Storage layer
      {Mosaic.Config, []},
      {Mosaic.StorageManager, []},
      {Mosaic.ConnectionPool, []},
      
      # Routing and indexing
      {Mosaic.ShardRouter, []},
      {Mosaic.BloomFilterManager, []},
      {Mosaic.RoutingMaintenance, []},
      
      # Embedding services
      {Mosaic.EmbeddingService, []},
      {Mosaic.EmbeddingCache, []},
      
      # Query execution
      {Mosaic.QueryEngine, []},
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

    opts = [strategy: :one_for_one, name: Mosaic.Supervisor]
    Logger.info("Starting supervisor with #{length(children)} children...")
    Supervisor.start_link(children, opts)
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

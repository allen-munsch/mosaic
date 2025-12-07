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
    
    children = [
      # Cluster coordination
      {Cluster.Supervisor, [topologies(), [name: Mosaic.ClusterSupervisor]]},

      # Storage layer
      {Mosaic.StorageManager, []},
      {Mosaic.ConnectionPool, []},

      Mosaic.WorkerPool.child_spec(name: :router_pool, worker: Mosaic.ShardRouter.Worker, size: 10),

      # Cache (ETS or Redis based on config)
      cache_child_spec(),

      # Shard routing
      # {Mosaic.ShardRouter, []}, # Replaced by the chosen index strategy
      # {Mosaic.BloomFilterManager, []}, # These are now managed by the strategy
      # {Mosaic.RoutingMaintenance, []}, # These are now managed by the strategy

      index_strategy_child_spec(),

      # Embeddings
      {Nx.Serving,
        serving: create_embedding_serving(),
        name: MosaicEmbedding,
        batch_size: 16,
        batch_timeout: 100},
      {Mosaic.EmbeddingCache, []},

      # Indexer (manages active shard for document ingestion)
      # Handled by the selected index strategy now.
      # {Mosaic.Indexer, []},

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

      # API
      {Plug.Cowboy, scheme: :http, plug: Mosaic.API, options: [port: port()]}
    ]
    
    configure_nx_backend()
    Supervisor.start_link(children, strategy: :one_for_one, name: Mosaic.Supervisor)
  end

  defp create_embedding_serving do
    {:ok, model_info} = Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"})
    Bumblebee.Text.text_embedding(model_info, tokenizer,
      compile: [batch_size: 16, sequence_length: 256],
      defn_options: [compiler: EXLA]
    )
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
    strategy_module = case Mosaic.Config.get(:index_strategy) do
      "quantized" -> Mosaic.Index.Strategy.Quantized
      _ -> Mosaic.Index.Strategy.Centroid
    end
    
    {Mosaic.Index.Supervisor, strategy: strategy_module}
  end

  defp port, do: System.get_env("PORT", "4040") |> String.to_integer()
end

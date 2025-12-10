defmodule Mosaic.Config do
  @moduledoc """
  Provides application-wide configuration.
  Reads from the application environment, with defaults.
  """

  @defaults %{
    storage_path: "/tmp/mosaic/shards",
    routing_db_path: "/tmp/mosaic/routing/index.db",
    nx_backend: "exla",
    nx_client: "host",
    cache_path: "/tmp/mosaic/cache",
    embedding_model: "local",
    embedding_dim: 384,
    embedding_batch_size: 32,
    embedding_batch_timeout_ms: 100,
    openai_api_key: nil,
    huggingface_api_key: nil,
    embedding_cache_max_size: 100_000,
    cache_backend: "ets",
    shard_size: 10_000,
    shard_depth: 3,
    default_shard_limit: 50,
    default_result_limit: 20,
    query_timeout: 10_000,
    query_cache_ttl_seconds: 300,
    redis_url: "redis://localhost:6379/1",
    routing_cache_size: 10_000,
    routing_cache_max_size: 10_000,
    routing_cache_refresh_interval_ms: 60_000,
    min_similarity: 0.1,
    failure_threshold: 5,
    success_threshold: 3,
    timeout_ms: 60_000,
    crawl_delay_ms: 1000,
    max_crawl_depth: 3,
    pagerank_iterations: 10,
    pagerank_damping: 0.85,
    pagerank_interval_hours: 24,
    weight_vector: 0.6,
    weight_pagerank: 0.2,
    weight_freshness: 0.1,
    weight_text_match: 0.1,
    fusion_strategy: "weighted_sum",
    min_score: 0.0,
    index_strategy: "hnsw",  # or centroid, hnsw, ivf, pq see: lib/mosaic/index/
    quantized_bins: 16,
    quantized_dims_per_level: 8,
    quantized_cell_capacity: 10_000,
    quantized_search_radius: 1,
    # HNSW config
    hnsw_m: 16,
    hnsw_ef_construction: 200,
    hnsw_ef_search: 50,
    hnsw_distance_fn: :cosine,
    # Binary/XOR config
    binary_bits: 256,
    binary_quantization: :mean,
    # IVF config
    ivf_n_lists: 100,
    ivf_n_probe: 10,
    # PQ config
    pq_m: 8,
    pq_k_sub: 256
  }

  def get(key, default \\ nil) do
    default = default || @defaults[key]
    Application.get_env(:mosaic, key, default)
  end

  def get_all do
    Application.get_env(:mosaic, [])
  end

  def update_setting(key, value) do
    Application.put_env(:mosaic, key, value)
  end
end

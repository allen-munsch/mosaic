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
    pq_k_sub: 256,
    # ── Graph DB config ──────────────────────────────────
    graph_enabled: true,
    graph_shard_size: 50_000,
    # ── Matryoshka embeddings: cascaded dimension levels ──
    matryoshka_levels: [64, 128, 256, 384],
    matryoshka_coarse_level: 64,
    matryoshka_fine_level: 384,
    matryoshka_cascade_factors: %{64 => 50, 128 => 10, 256 => 3},
    # ── Handle registry ─────────────────────────────────
    handle_registry_enabled: true,
    handle_max_count: 10_000,
    handle_default_ttl_seconds: 3600,
    handle_preview_length: 120,
    handle_db_path: "/tmp/mosaic/handles/handles.db",
    # ── MCP server ──────────────────────────────────────
    mcp_enabled: false,
    mcp_transport: "stdio",
    # ── AST ingestion ───────────────────────────────────
    ast_tree_sitter_backend: "ast-grep",
    ast_supported_languages: ["elixir", "python", "rust", "go", "javascript", "typescript"],
    ast_max_file_size_bytes: 1_000_000,
    ast_parallel_workers: 8,
    # ── Tree-sitter grammars (installed via npm) ─────────
    tree_sitter_grammars: %{
      elixir: "tree-sitter-elixir",
      python: "tree-sitter-python",
      rust: "tree-sitter-rust",
      go: "tree-sitter-go",
      javascript: "tree-sitter-javascript",
      typescript: "tree-sitter-typescript"
    },
    # ── Authentication ──────────────────────────────────
    auth_enabled: false,
    jwt_secret: "mosaic-dev-secret-change-in-production",
    jwt_issuer: "mosaicdb",
    jwt_audience: "mosaicdb-api",
    jwt_ttl: 86400,
    auth_db_path: "/tmp/mosaic/auth.db",
    # ── Multi-tenancy ───────────────────────────────────
    tenancy_enabled: false,
    # ── Consensus (:ra Raft cluster) ────────────────────
    consensus_enabled: false,
    cluster_peers: [],
    # ── Embedding model configuration ───────────────────
    embedding_model_name: "all-MiniLM-L6-v2",
    embedding_provider: "local",
    # ── API ─────────────────────────────────────────────
    api_rate_limit_per_minute: 1000,
    api_max_body_size: 10_000_000
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

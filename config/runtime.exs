import Config

# ── Runtime configuration ──────────────────────────────────────
# Maps environment variables (set by Helm chart / Docker) to :mosaic application config.
# Only overrides config when corresponding env var is explicitly set;
# otherwise preserves compile-time config (dev/test use config/*.exs).

# Helper: coerce a string value to its Elixir type
parse_val = fn
  "true" -> true
  "false" -> false
  val ->
    case Integer.parse(val) do
      {n, ""} -> n
      _ ->
        case Float.parse(val) do
          {f, ""} -> f
          _ -> val
        end
    end
end

env = fn _key, env_var, _default ->
  case System.get_env(env_var) do
    nil -> :keep
    val -> parse_val.(val)
  end
end

env_bool = fn _key, env_var, _default ->
  case System.get_env(env_var) do
    nil -> :keep
    val -> val in ["true", "1"]
  end
end

# Helper: only set config if env var was provided
maybe_config = fn key, value ->
  if value != :keep, do: config(:mosaic, [{key, value}])
end

# ── Core paths ─────────────────────────────────────────────────
maybe_config.(:storage_path, env.(:storage_path, "STORAGE_PATH", nil))
maybe_config.(:routing_db_path, env.(:routing_db_path, "ROUTING_DB_PATH", nil))

# ── Search & indexing ──────────────────────────────────────────
maybe_config.(:index_strategy, env.(:index_strategy, "INDEX_STRATEGY", nil))
maybe_config.(:cache_backend, env.(:cache_backend, "CACHE_BACKEND", nil))
maybe_config.(:min_similarity, env.(:min_similarity, "MIN_SIMILARITY", nil))
maybe_config.(:query_timeout, env.(:query_timeout, "QUERY_TIMEOUT", nil))
maybe_config.(:default_result_limit, env.(:default_result_limit, "DEFAULT_RESULT_LIMIT", nil))

# ── Feature flags ──────────────────────────────────────────────
maybe_config.(:graph_enabled, env_bool.(:graph_enabled, "GRAPH_ENABLED", nil))
maybe_config.(:mcp_enabled, env_bool.(:mcp_enabled, "MCP_ENABLED", nil))
maybe_config.(:handle_registry_enabled, env_bool.(:handle_registry_enabled, "HANDLE_REGISTRY_ENABLED", nil))

# ── Authentication ─────────────────────────────────────────────
maybe_config.(:auth_enabled, env_bool.(:auth_enabled, "AUTH_ENABLED", nil))
maybe_config.(:jwt_secret, env.(:jwt_secret, "JWT_SECRET", nil))
maybe_config.(:api_key_encryption_key, env.(:api_key_encryption_key, "API_KEY_ENCRYPTION_KEY", nil))

# ── Redis (distributed cache) ──────────────────────────────────
maybe_config.(:redis_url, env.(:redis_url, "REDIS_URL", nil))

# ── Embeddings ─────────────────────────────────────────────────
maybe_config.(:embedding_dim, env.(:embedding_dim, "EMBEDDING_DIM", nil))
maybe_config.(:embedding_model, env.(:embedding_model, "EMBEDDING_MODEL", nil))
maybe_config.(:embedding_provider, env.(:embedding_provider, "EMBEDDING_PROVIDER", nil))
maybe_config.(:embedding_model_name, env.(:embedding_model_name, "EMBEDDING_MODEL_NAME", nil))

# ── Cluster (Erlang distribution) ──────────────────────────────
maybe_config.(:consensus_enabled, env_bool.(:consensus_enabled, "CLUSTER_ENABLED", nil))

# ── Joken (JWT) configuration ─────────────────────────────────
jwt_algorithm = case System.get_env("JWT_ALGORITHM") do
  nil -> nil
  val -> parse_val.(val)
end
jwt_secret = case System.get_env("JWT_SECRET") do
  nil -> nil
  val -> parse_val.(val)
end

if jwt_algorithm && jwt_secret do
  config :joken,
    default_signer: [
      signer_alg: jwt_algorithm,
      key_octet: jwt_secret
    ]
end

# ── Remote storage backend (S3/MinIO) ──────────────────────────
storage_backend = case System.get_env("STORAGE_BACKEND", "local") do
  "s3" -> Mosaic.StorageBackend.S3
  _ -> Mosaic.StorageBackend.Local
end

config :mosaic,
  storage_backend: storage_backend,
  storage_backend_opts: [
    bucket: System.get_env("S3_BUCKET", "mosaic-shards"),
    endpoint: System.get_env("S3_ENDPOINT", "http://minio:9000"),
    access_key: System.get_env("S3_ACCESS_KEY", ""),
    secret_key: System.get_env("S3_SECRET_KEY", ""),
    region: System.get_env("S3_REGION", "us-east-1")
  ]

# ── Shard sync (periodic push to remote storage) ───────────────
shard_sync_enabled = case System.get_env("SHARD_SYNC_ENABLED", "false") do
  "true" -> true
  "1" -> true
  _ -> false
end

config :mosaic,
  shard_sync_enabled: shard_sync_enabled,
  shard_sync_interval_ms: String.to_integer(System.get_env("SHARD_SYNC_INTERVAL_MS", "60000"))

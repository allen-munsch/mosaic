import Config

config :logger, level: :warn

# Use random port for tests to avoid conflicts
config :mosaic, http_port: 0

# Use temp directories for tests to avoid permission issues
tmp = System.tmp_dir!()
ts = System.monotonic_time()
test_dir = Path.join(tmp, "mosaic_test_#{ts}")

config :mosaic,
  routing_db_path: Path.join(test_dir, "routing/index.db"),
  cache_path: Path.join(test_dir, "cache"),
  auth_db_path: Path.join(test_dir, "auth.db"),
  handle_db_path: Path.join(test_dir, "handles/handles.db"),
  semantic_cache_path: Path.join(test_dir, "semantic_cache.db"),
  jwt_secret: "test-jwt-secret-do-not-use-in-production"

# Disable features that need external services or cluster setup
config :mosaic,
  consensus_enabled: false,
  auth_enabled: false,
  tenancy_enabled: false,
  mcp_enabled: false,
  shard_sync_enabled: false

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
      {Mosaic.API, port: get_port()}
    ]

    opts = [strategy: :one_for_one, name: Mosaic.Supervisor]
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

# ============================================================================
# Enhanced Configuration Management
# ============================================================================

defmodule Mosaic.Config do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    config = %{
      # Storage
      storage_path: System.get_env("STORAGE_PATH", "/data/shards"),
      routing_db_path: System.get_env("ROUTING_DB_PATH", "/data/routing/index.db"),
      cache_path: System.get_env("CACHE_PATH", "/data/cache"),
      
      # Embeddings
      embedding_model: System.get_env("EMBEDDING_MODEL", "local"),
      embedding_dim: System.get_env("EMBEDDING_DIM", "1024") |> String.to_integer(),
      embedding_batch_size: System.get_env("EMBEDDING_BATCH_SIZE", "32") |> String.to_integer(),
      
      # Sharding
      shard_size: System.get_env("SHARD_SIZE", "10000") |> String.to_integer(),
      shard_depth: System.get_env("SHARD_DEPTH", "3") |> String.to_integer(),
      
      # Query
      default_shard_limit: System.get_env("DEFAULT_SHARD_LIMIT", "50") |> String.to_integer(),
      default_result_limit: System.get_env("DEFAULT_RESULT_LIMIT", "20") |> String.to_integer(),
      query_timeout: System.get_env("QUERY_TIMEOUT", "10000") |> String.to_integer(),
      
      # Routing
      routing_cache_size: System.get_env("ROUTING_CACHE_SIZE", "10000") |> String.to_integer(),
      min_similarity: System.get_env("MIN_SIMILARITY", "0.1") |> String.to_float(),
      
      # Circuit breaker
      failure_threshold: System.get_env("FAILURE_THRESHOLD", "5") |> String.to_integer(),
      success_threshold: System.get_env("SUCCESS_THRESHOLD", "3") |> String.to_integer(),
      timeout_ms: System.get_env("CIRCUIT_TIMEOUT_MS", "60000") |> String.to_integer(),
      
      # Crawler
      crawl_delay_ms: System.get_env("CRAWL_DELAY_MS", "1000") |> String.to_integer(),
      max_crawl_depth: System.get_env("MAX_CRAWL_DEPTH", "3") |> String.to_integer(),
      
      # PageRank
      pagerank_iterations: System.get_env("PAGERANK_ITERATIONS", "10") |> String.to_integer(),
      pagerank_damping: System.get_env("PAGERANK_DAMPING", "0.85") |> String.to_float(),
      pagerank_interval_hours: System.get_env("PAGERANK_INTERVAL_HOURS", "24") |> String.to_integer()
    }
    
    # Ensure directories exist
    File.mkdir_p!(config.storage_path)
    File.mkdir_p!(Path.dirname(config.routing_db_path))
    File.mkdir_p!(config.cache_path)
    
    {:ok, config}
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def get_all(), do: GenServer.call(__MODULE__, :get_all)

  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  def handle_call(:get_all, _from, state) do
    {:reply, state, state}
  end
end

# ============================================================================
# Enhanced Embedding Service with Batching and Caching
# ============================================================================

defmodule Mosaic.DB do
  def execute(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    :ok = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end
end


defmodule Mosaic.EmbeddingService do
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :model_type,
      :model_ref,
      :batch_queue,
      :batch_timer,
      :pending_requests,
      :batch_size,
      :batch_timeout_ms
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    model_type = Mosaic.Config.get(:embedding_model)
    batch_size = Mosaic.Config.get(:embedding_batch_size)
    
    model_ref = case model_type do
      "local" -> load_local_model()
      "openai" -> :openai
      "huggingface" -> :huggingface
      _ -> load_local_model()
    end
    
    state = %State{
      model_type: model_type,
      model_ref: model_ref,
      batch_queue: :queue.new(),
      batch_timer: nil,
      pending_requests: %{},
      batch_size: batch_size,
      batch_timeout_ms: 100
    }
    
    {:ok, state}
  end

  def encode(text) when is_binary(text) do
    # Check cache first
    case Mosaic.EmbeddingCache.get(text) do
      {:ok, embedding} -> embedding
      :miss -> 
        GenServer.call(__MODULE__, {:encode, text}, 30_000)
    end
  end

  def encode_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:encode_batch, texts}, 30_000)
  end

  def handle_call({:encode, text}, from, state) do
    # Add to batch queue
    new_queue = :queue.in({text, from}, state.batch_queue)
    queue_size = :queue.len(new_queue)
    
    new_state = %{state | batch_queue: new_queue}
    
    # Process immediately if batch is full
    if queue_size >= state.batch_size do
      process_batch(new_state)
    else
      # Schedule batch processing if not already scheduled
      timer = if state.batch_timer == nil do
        Process.send_after(self(), :process_batch, state.batch_timeout_ms)
      else
        state.batch_timer
      end
      
      {:noreply, %{new_state | batch_timer: timer}}
    end
  end

  def handle_call({:encode_batch, texts}, _from, state) do
    embeddings = generate_embeddings(texts, state.model_type, state.model_ref)
    
    # Cache results
    Enum.zip(texts, embeddings)
    |> Enum.each(fn {text, embedding} ->
      Mosaic.EmbeddingCache.put(text, embedding)
    end)
    
    {:reply, embeddings, state}
  end

  def handle_info(:process_batch, state) do
    new_state = process_batch(state)
    {:noreply, %{new_state | batch_timer: nil}}
  end

  defp process_batch(state) do
    if :queue.is_empty(state.batch_queue) do
      state
    else
      # Extract batch
      {batch, remaining_queue} = extract_batch(state.batch_queue, state.batch_size)
      
      # Generate embeddings
      texts = Enum.map(batch, fn {text, _from} -> text end)
      embeddings = generate_embeddings(texts, state.model_type, state.model_ref)
      
      # Cache and reply to callers
      Enum.zip(batch, embeddings)
      |> Enum.each(fn {{text, from}, embedding} ->
        Mosaic.EmbeddingCache.put(text, embedding)
        GenServer.reply(from, embedding)
      end)
      
      %{state | batch_queue: remaining_queue}
    end
  end

  defp extract_batch(queue, max_size) do
    extract_batch_recursive(queue, [], max_size)
  end

  defp extract_batch_recursive(queue, acc, 0) do
    {Enum.reverse(acc), queue}
  end

  defp extract_batch_recursive(queue, acc, remaining) do
    case :queue.out(queue) do
      {{:value, item}, new_queue} ->
        extract_batch_recursive(new_queue, [item | acc], remaining - 1)
      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp generate_embeddings(texts, :openai, _ref) do
    generate_openai_embeddings(texts)
  end

  defp generate_embeddings(texts, :local, model_ref) do
    generate_local_embeddings(texts, model_ref)
  end

  defp generate_embeddings(texts, :huggingface, _ref) do
    generate_huggingface_embeddings(texts)
  end

  defp generate_openai_embeddings(texts) do
    api_key = System.get_env("OPENAI_API_KEY")
    
    texts
    |> Enum.chunk_every(100)
    |> Enum.flat_map(fn batch ->
      response = Req.post!(
        "https://api.openai.com/v1/embeddings",
        json: %{
          input: batch,
          model: "text-embedding-3-large"
        },
        headers: [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
      )
      
      response.body["data"]
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(& &1["embedding"])
    end)
  rescue
    error ->
      Logger.error("OpenAI embedding generation failed: #{inspect(error)}")
      Enum.map(texts, fn _ -> List.duplicate(0.0, 1536) end)
  end

  defp generate_local_embeddings(texts, _model_ref) do
    # Placeholder for local model integration
    # Use Bumblebee/Nx for local inference
    Logger.warning("Local embedding generation not implemented, using dummy embeddings")
    embedding_dim = Mosaic.Config.get(:embedding_dim)
    Enum.map(texts, fn _ -> List.duplicate(0.1, embedding_dim) end)
  end

  defp generate_huggingface_embeddings(texts) do
    Logger.warning("HuggingFace embedding generation not implemented, using dummy embeddings")
    embedding_dim = Mosaic.Config.get(:embedding_dim)
    Enum.map(texts, fn _ -> List.duplicate(0.1, embedding_dim) end)
  end

  defp load_local_model do
    # Placeholder for local model loading
    # Use Bumblebee to load models
    nil
  end
end

# ============================================================================
# Embedding Cache with LRU Eviction
# ============================================================================

defmodule Mosaic.EmbeddingCache do
  use GenServer

  defmodule State do
    defstruct [:cache, :lru_queue, :max_size, :current_size]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    state = %State{
      cache: %{},
      lru_queue: :queue.new(),
      max_size: 100_000,
      current_size: 0
    }
    
    {:ok, state}
  end

  def get(text), do: GenServer.call(__MODULE__, {:get, text})
  def put(text, embedding), do: GenServer.cast(__MODULE__, {:put, text, embedding})

  def handle_call({:get, text}, _from, state) do
    case Map.get(state.cache, hash_text(text)) do
      nil -> {:reply, :miss, state}
      embedding -> {:reply, {:ok, embedding}, state}
    end
  end

  def handle_cast({:put, text, embedding}, state) do
    key = hash_text(text)
    
    # Evict if necessary
    new_state = if state.current_size >= state.max_size and not Map.has_key?(state.cache, key) do
      evict_lru(state)
    else
      state
    end
    
    # Add to cache
    new_cache = Map.put(new_state.cache, key, embedding)
    new_queue = :queue.in(key, new_state.lru_queue)
    
    {:noreply, %{new_state | 
      cache: new_cache, 
      lru_queue: new_queue,
      current_size: map_size(new_cache)
    }}
  end

  defp evict_lru(state) do
    case :queue.out(state.lru_queue) do
      {{:value, key}, new_queue} ->
        %{state |
          cache: Map.delete(state.cache, key),
          lru_queue: new_queue,
          current_size: state.current_size - 1
        }
      {:empty, _} ->
        state
    end
  end

  defp hash_text(text) do
    :crypto.hash(:sha256, text) |> Base.encode16()
  end
end

# ============================================================================
# Enhanced Shard Router with Bloom Filters
# ============================================================================

defmodule Mosaic.ShardRouter do
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :routing_conn,
      :shard_cache,
      :bloom_filters,
      :cache_hits,
      :cache_misses
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    routing_db_path = Mosaic.Config.get(:routing_db_path)
    
    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)
    
    # Optimize for read-heavy workload
    Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size=-128000;")  # 128MB
    Exqlite.Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size=268435456;")  # 256MB mmap
    
    # Initialize schema
    initialize_routing_schema(conn)
    
    # Load bloom filters
    bloom_filters = load_bloom_filters(conn)
    
    # Preload hot shards
    shard_cache = preload_hot_shards(conn, 1000)
    
    state = %State{
      routing_conn: conn,
      shard_cache: shard_cache,
      bloom_filters: bloom_filters,
      cache_hits: 0,
      cache_misses: 0
    }
    
    {:ok, state}
  end

  defp initialize_routing_schema(conn) do
    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS shard_metadata (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL,
      doc_count INTEGER DEFAULT 0,
      query_count INTEGER DEFAULT 0,
      last_accessed DATETIME,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      status TEXT DEFAULT 'active',
      bloom_filter BLOB
    );
    """)

    Exqlite.Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS shard_centroids (
      shard_id TEXT PRIMARY KEY,
      centroid BLOB NOT NULL,
      centroid_norm REAL NOT NULL,
      FOREIGN KEY (shard_id) REFERENCES shard_metadata(id) ON DELETE CASCADE
    );
    """)

    Exqlite.Sqlite3.execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_shard_status_queries 
    ON shard_metadata(status, query_count DESC);
    """)

    Exqlite.Sqlite3.execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_shard_accessed 
    ON shard_metadata(last_accessed DESC) WHERE status = 'active';
    """)

    Exqlite.Sqlite3.execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_centroid_norm 
    ON shard_centroids(centroid_norm);
    """)
  end

  def find_similar_shards(query_vector, limit, opts \\ []) do
    GenServer.call(__MODULE__, {:find_similar, query_vector, limit, opts}, 30_000)
  end

  def handle_call({:find_similar, query_vector, limit, opts}, _from, state) do
    use_cache = Keyword.get(opts, :use_cache, true)
    min_similarity = Keyword.get(opts, :min_similarity, Mosaic.Config.get(:min_similarity))
    
    # Use bloom filter for quick filtering if keywords provided
    filtered_shards = case Keyword.get(opts, :keywords) do
      nil -> nil
      keywords -> filter_by_bloom(keywords, state.bloom_filters)
    end
    
    shards = if use_cache && map_size(state.shard_cache) > 0 do
      find_similar_cached(query_vector, limit, min_similarity, filtered_shards, state)
    else
      find_similar_db(query_vector, limit, min_similarity, filtered_shards, state)
    end
    
    # Update access stats
    update_access_stats(shards, state.routing_conn)
    
    {:reply, shards, state}
  end

  defp find_similar_cached(query_vector, limit, min_similarity, filter_ids, state) do
    query_norm = VectorMath.norm(query_vector)
    
    candidates = if filter_ids do
      Map.take(state.shard_cache, filter_ids)
    else
      state.shard_cache
    end
    
    candidates
    |> Map.values()
    |> Enum.map(fn shard ->
      centroid_vector = :erlang.binary_to_term(shard.centroid)
      similarity = VectorMath.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)
      Map.put(shard, :similarity, similarity)
    end)
    |> Enum.filter(&(&1.similarity >= min_similarity))
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
  end

  defp find_similar_db(query_vector, limit, min_similarity, filter_ids, state) do
    query_norm = VectorMath.norm(query_vector)
    
    where_clause = if filter_ids do
      shard_list = Enum.join(Enum.map(filter_ids, &"'#{&1}'"), ",")
      "AND sm.id IN (#{shard_list})"
    else
      ""
    end
    
    {:ok, statement} = Exqlite.Sqlite3.prepare(state.routing_conn, """
      SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm
      FROM shard_metadata sm
      JOIN shard_centroids sc ON sm.id = sc.shard_id
      WHERE sm.status = 'active' #{where_clause}
      ORDER BY sm.query_count DESC
      LIMIT 5000
    """)
    
    Exqlite.Sqlite3.bind(statement, [])
    
    case Exqlite.Sqlite3.fetch_all(state.routing_conn, statement) do
      {:ok, rows} ->
        rows
        |> Enum.map(&row_to_shard/1)
        |> Enum.map(fn shard ->
          centroid_vector = :erlang.binary_to_term(shard.centroid)
          similarity = VectorMath.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)
          Map.put(shard, :similarity, similarity)
        end)
        |> Enum.filter(&(&1.similarity >= min_similarity))
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)
        
      {:error, reason} ->
        Logger.error("Database shard search failed: #{inspect(reason)}")
        []
    end
  end

  defp filter_by_bloom(keywords, bloom_filters) do
    bloom_filters
    |> Enum.filter(fn {_shard_id, bloom} ->
      Enum.all?(keywords, &BloomFilter.member?(bloom, &1))
    end)
    |> Enum.map(fn {shard_id, _bloom} -> shard_id end)
  end

  defp row_to_shard([id, path, doc_count, query_count, centroid, centroid_norm]) do
    %{
      id: id,
      path: path,
      doc_count: doc_count,
      query_count: query_count,
      centroid: centroid,
      centroid_norm: centroid_norm
    }
  end

  defp load_bloom_filters(conn) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, """
      SELECT id, bloom_filter
      FROM shard_metadata
      WHERE status = 'active' AND bloom_filter IS NOT NULL
    """)
    
    Exqlite.Sqlite3.bind(statement, [])
    
    case Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, rows} ->
        rows
        |> Enum.map(fn [id, bloom_blob] ->
          {id, :erlang.binary_to_term(bloom_blob)}
        end)
        |> Map.new()
      _ ->
        %{}
    end
  end

  defp preload_hot_shards(conn, limit) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, """
      SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm
      FROM shard_metadata sm
      JOIN shard_centroids sc ON sm.id = sc.shard_id
      WHERE sm.status = 'active'
      ORDER BY sm.query_count DESC, sm.last_accessed DESC
      LIMIT ?
    """)
    
    Exqlite.Sqlite3.bind(statement, [limit])
    
    case Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, rows} ->
        rows
        |> Enum.map(&{&1 |> hd(), row_to_shard(&1)})
        |> Map.new()
      _ ->
        %{}
    end
  end

  defp update_access_stats(shards, conn) do
    shard_ids = Enum.map(shards, & &1.id)
    placeholders = Enum.map_join(shard_ids, ",", fn _ -> "?" end)
    
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, """
      UPDATE shard_metadata
      SET query_count = query_count + 1,
          last_accessed = CURRENT_TIMESTAMP
      WHERE id IN (#{placeholders})
    """)
    
    Exqlite.Sqlite3.bind(statement, shard_ids)
    Exqlite.Sqlite3.step(conn, statement)
  end

  def handle_cast({:register_shard, shard_info}, state) do
    %{id: id, path: path, centroid: centroid, doc_count: doc_count, bloom_filter: bloom} = shard_info
    
    centroid_norm = VectorMath.norm(centroid)
    centroid_blob = :erlang.term_to_binary(centroid)
    bloom_blob = :erlang.term_to_binary(bloom)
    
    Mosaic.DB.execute(state.routing_conn, """
    INSERT OR REPLACE INTO shard_metadata (id, path, doc_count, bloom_filter, updated_at)
    VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
    """, [id, path, doc_count, bloom_blob])

    Mosaic.DB.execute(state.routing_conn, """
    INSERT OR REPLACE INTO shard_centroids (shard_id, centroid, centroid_norm)
    VALUES (?, ?, ?)
    """, [id, centroid_blob, centroid_norm])

    # Update caches
    cached_shard = %{
      id: id,
      path: path,
      doc_count: doc_count,
      query_count: 0,
      centroid: centroid_blob,
      centroid_norm: centroid_norm
    }

    new_cache = Map.put(state.shard_cache, id, cached_shard)
    new_blooms = Map.put(state.bloom_filters, id, bloom)
    
    {:noreply, %{state | shard_cache: new_cache, bloom_filters: new_blooms}}
  end
end

# ============================================================================
# Vector Math Utilities
# ============================================================================

defmodule VectorMath do
  def cosine_similarity(v1, norm1, v2, norm2) when is_binary(v2) do
    v2_vector = :erlang.binary_to_term(v2)
    dot_product = dot(v1, v2_vector)
    dot_product / (norm1 * norm2)
  end

  def cosine_similarity(v1, norm1, v2, norm2) do
    dot_product = dot(v1, v2)
    dot_product / (norm1 * norm2)
  end

  def dot(v1, v2) do
    Enum.zip(v1, v2)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
  end

  def norm(vector) do
    vector
    |> Enum.reduce(0.0, fn x, acc -> acc + x * x end)
    |> :math.sqrt()
  end
end

# ============================================================================
# Bloom Filter Manager
# ============================================================================

defmodule Mosaic.BloomFilterManager do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def create_bloom_filter(terms, opts \\ []) do
    size = Keyword.get(opts, :size, 10_000)
    num_hashes = Keyword.get(opts, :num_hashes, 5)
    
    bloom = BloomFilter.new(size, num_hashes)
    
    Enum.reduce(terms, bloom, fn term, acc ->
      BloomFilter.add(acc, term)
    end)
  end
end

defmodule BloomFilter do
  defstruct [:bits, :size, :num_hashes]

  def new(size, num_hashes) do
    %__MODULE__{
      bits: :array.new(size, default: 0),
      size: size,
      num_hashes: num_hashes
    }
  end

  def add(%__MODULE__{} = bloom, item) do
    indices = hash_indices(item, bloom.size, bloom.num_hashes)
    
    new_bits = Enum.reduce(indices, bloom.bits, fn idx, bits ->
      :array.set(idx, 1, bits)
    end)
    
    %{bloom | bits: new_bits}
  end

  def member?(%__MODULE__{} = bloom, item) do
    indices = hash_indices(item, bloom.size, bloom.num_hashes)
    
    Enum.all?(indices, fn idx ->
      :array.get(idx, bloom.bits) == 1
    end)
  end

  defp hash_indices(item, size, num_hashes) do
    base_hash = :erlang.phash2(item)
    
    for i <- 0..(num_hashes - 1) do
      rem(base_hash + i * :erlang.phash2(i), size)
    end
  end
end

# ============================================================================
# Connection Pool for SQLite
# ============================================================================

defmodule Mosaic.ConnectionPool do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{connections: %{}, max_per_shard: 5}}
  end

  def checkout(shard_path), do: GenServer.call(__MODULE__, {:checkout, shard_path})
  def checkin(shard_path, conn), do: GenServer.cast(__MODULE__, {:checkin, shard_path, conn})

  def handle_call({:checkout, shard_path}, _from, state) do
    case Map.get(state.connections, shard_path) do
      nil ->
        case Exqlite.Sqlite3.open(shard_path, mode: :readonly) do
          {:ok, conn} ->
            {:reply, {:ok, conn}, state}
          error ->
            {:reply, error, state}
        end
      
      [conn | rest] ->
        new_conns = Map.put(state.connections, shard_path, rest)
        {:reply, {:ok, conn}, %{state | connections: new_conns}}
    end
  end

  def handle_cast({:checkin, shard_path, conn}, state) do
    current = Map.get(state.connections, shard_path, [])
    
    new_conns = if length(current) < state.max_per_shard do
      Map.put(state.connections, shard_path, [conn | current])
    else
      Exqlite.Sqlite3.close(conn)
      state.connections
    end
    
    {:noreply, %{state | connections: new_conns}}
  end
end

# ============================================================================
# Health Check and Monitoring
# ============================================================================

defmodule Mosaic.HealthCheck do
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_health_check()
    {:ok, %{last_check: nil, status: :healthy}}
  end

  def handle_info(:check_health, state) do
    health_status = perform_health_check()
    
    Logger.info("Health check completed: #{inspect(health_status)}")
    
    schedule_health_check()
    {:noreply, %{state | last_check: DateTime.utc_now(), status: health_status.status}}
  end

  defp schedule_health_check do
    Process.send_after(self(), :check_health, 30_000)  # Every 30 seconds
  end

  defp perform_health_check do
    checks = [
      check_router_health(),
      check_embedding_service(),
      check_storage(),
      check_memory()
    ]
    
    failed = Enum.filter(checks, fn {_name, status} -> status != :ok end)
    
    %{
      timestamp: DateTime.utc_now(),
      status: if(length(failed) == 0, do: :healthy, else: :degraded),
      checks: Map.new(checks),
      failed_checks: Enum.map(failed, fn {name, _} -> name end)
    }
  end

  defp check_router_health do
    try do
      # Try a simple routing operation
      test_vector = List.duplicate(0.1, Mosaic.Config.get(:embedding_dim))
      Mosaic.ShardRouter.find_similar_shards(test_vector, 1, use_cache: true)
      {:router, :ok}
    rescue
      _ -> {:router, :failed}
    end
  end

  defp check_embedding_service do
    try do
      Mosaic.EmbeddingService.encode("health check")
      {:embeddings, :ok}
    rescue
      _ -> {:embeddings, :failed}
    end
  end

  defp check_storage do
    storage_path = Mosaic.Config.get(:storage_path)
    
    case File.stat(storage_path) do
      {:ok, %{access: access}} when access in [:read, :read_write] ->
        {:storage, :ok}
      _ ->
        {:storage, :failed}
    end
  end

  defp check_memory do
    memory = :erlang.memory()
    total_mb = memory[:total] / 1_024 / 1_024
    
    if total_mb < 8_000 do  # Less than 8GB
      {:memory, :ok}
    else
      {:memory, :warning}
    end
  end
end

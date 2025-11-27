defmodule Mosaic.ShardRouter do
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :routing_conn,
      :shard_cache,
      :bloom_filters,
      :cache_hits,
      :cache_misses,
      :lru_queue,
      :max_size,
      :current_size
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    routing_db_path = Mosaic.Config.get(:routing_db_path)
    routing_cache_max_size = Mosaic.Config.get(:routing_cache_max_size)
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)

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
    {shard_cache, lru_queue} = preload_hot_shards(conn, routing_cache_max_size)

    state = %State{
      routing_conn: conn,
      shard_cache: shard_cache,
      bloom_filters: bloom_filters,
      cache_hits: 0,
      cache_misses: 0,
      lru_queue: lru_queue,
      max_size: routing_cache_max_size,
      current_size: map_size(shard_cache)
    }

    Process.send_after(self(), :refresh_cache, refresh_interval)
    {:ok, state}
  end

  def handle_info(:refresh_cache, state) do
    Logger.info("Refreshing ShardRouter cache...")

    # Reload bloom filters
    new_bloom_filters = load_bloom_filters(state.routing_conn)

    # Reload hot shards and LRU queue
    {new_shard_cache, new_lru_queue} = preload_hot_shards(state.routing_conn, state.max_size)

    # Reschedule refresh
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)
    Process.send_after(self(), :refresh_cache, refresh_interval)

    {:noreply, %{state |
      shard_cache: new_shard_cache,
      bloom_filters: new_bloom_filters,
      lru_queue: new_lru_queue,
      current_size: map_size(new_shard_cache)
    }}
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

  def reset_state(), do: GenServer.call(__MODULE__, :reset_state)

  def handle_call({:find_similar, query_vector, limit, opts}, _from, state) do
    min_similarity = Keyword.get(opts, :min_similarity, Mosaic.Config.get(:min_similarity))
    vector_math_impl = Keyword.get(opts, :vector_math_impl, VectorMath) # Get the VectorMath implementation

    # Use bloom filter for quick filtering if keywords provided
    filtered_shards = case Keyword.get(opts, :keywords) do
      nil -> nil
      keywords -> filter_by_bloom(keywords, state.bloom_filters)
    end

    {shards, new_state} = if map_size(state.shard_cache) > 0 do
      find_similar_lru(query_vector, limit, min_similarity, filtered_shards, vector_math_impl, state)
    else
      find_similar_db(query_vector, limit, min_similarity, filtered_shards, vector_math_impl, state)
      |> Enum.reduce({[], state}, fn shard, {acc, current_state} ->
        {new_cache, new_lru_queue, new_current_size} = add_shard_to_cache(shard, current_state)
        {[shard | acc], %{current_state | shard_cache: new_cache, lru_queue: new_lru_queue, current_size: new_current_size, cache_misses: current_state.cache_misses + 1}}
      end)
      |> (fn {shards, final_state} -> {Enum.reverse(shards), final_state} end).()
    end

    # Update access stats
    update_access_stats(shards, new_state.routing_conn)

    {:reply, {:ok, shards}, new_state}
  end

  def handle_call(:reset_state, _from, state) do
    routing_db_path = Mosaic.Config.get(:routing_db_path)
    routing_cache_max_size = Mosaic.Config.get(:routing_cache_max_size)

    # Re-open connection to ensure clean state for tests
    Exqlite.Sqlite3.close(state.routing_conn)
    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)

    # Re-initialize schema
    initialize_routing_schema(conn)

    # Reload bloom filters
    bloom_filters = load_bloom_filters(conn)

    # Preload hot shards
    {shard_cache, lru_queue} = preload_hot_shards(conn, routing_cache_max_size)

    new_state = %State{
      routing_conn: conn,
      shard_cache: shard_cache,
      bloom_filters: bloom_filters,
      cache_hits: 0,
      cache_misses: 0,
      lru_queue: lru_queue,
      max_size: routing_cache_max_size,
      current_size: map_size(shard_cache)
    }
    {:reply, :ok, new_state}
  end

  def handle_call(:list_all_shards, _from, state) do
    shards = state.shard_cache |> Map.values()
    {:reply, shards, state}
  end

  defp find_similar_lru(query_vector, limit, min_similarity, filter_ids, vector_math_impl, state) do
    query_norm = vector_math_impl.norm(query_vector)

    candidates = if filter_ids do
      Map.take(state.shard_cache, filter_ids)
    else
      state.shard_cache
    end

    {shards, new_lru_queue, new_cache_hits} = candidates
    |> Map.values()
    |> Enum.reduce({[], state.lru_queue, state.cache_hits}, fn shard, {acc_shards, current_lru, current_hits} ->
      centroid_vector = :erlang.binary_to_term(shard.centroid)
      similarity = vector_math_impl.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)

      if similarity >= min_similarity do
        new_lru = :queue.delete(shard.id, current_lru)
        new_lru = :queue.in(shard.id, new_lru)
        {[Map.put(shard, :similarity, similarity) | acc_shards], new_lru, current_hits + 1}
      else
        {acc_shards, current_lru, current_hits}
      end
    end)

    sorted_shards = shards
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)

    {sorted_shards, %{state | lru_queue: new_lru_queue, cache_hits: new_cache_hits}}
  end

  defp find_similar_db(query_vector, limit, min_similarity, filter_ids, vector_math_impl, state) do
    query_norm = vector_math_impl.norm(query_vector)

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
          similarity = vector_math_impl.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)
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
          {id, BloomFilter.from_binary(bloom_blob)}
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
        shard_cache = rows
        |> Enum.map(&{&1 |> hd(), row_to_shard(&1)})
        |> Map.new()

        lru_queue = rows
        |> Enum.map(&hd(&1))
        |> :queue.from_list()

        {shard_cache, lru_queue}
      _ ->
        {%{}, :queue.new()}
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

  defp add_shard_to_cache(shard, state) do
    new_cache = Map.put(state.shard_cache, shard.id, shard)
    new_lru_queue = :queue.in(shard.id, state.lru_queue)
    new_current_size = state.current_size + 1

    if new_current_size > state.max_size do
      {{:value, lru_key}, new_lru_queue_after_evict} = :queue.out(new_lru_queue)
      new_cache = Map.delete(new_cache, lru_key)
      {new_cache, new_lru_queue_after_evict, new_current_size - 1}
    else
      {new_cache, new_lru_queue, new_current_size}
    end
  end

  def handle_cast({:register_shard, shard_info}, state) do
    %{id: id, path: path, centroid: centroid, doc_count: doc_count, bloom_filter: bloom} = shard_info

    centroid_norm = VectorMath.norm(centroid)
    centroid_blob = :erlang.term_to_binary(centroid)
    bloom_blob = BloomFilter.to_binary(bloom)

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

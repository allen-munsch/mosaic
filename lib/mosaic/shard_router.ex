defmodule Mosaic.ShardRouter do
  use GenServer
  require Logger

  defmodule State do
    defstruct [:routing_conn, :cache_table, :access_table, :access_counts, :bloom_filters, :counter, :max_size, :cache_hits, :cache_misses]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    routing_db_path = Mosaic.Config.get(:routing_db_path)
    max_size = Mosaic.Config.get(:routing_cache_max_size)
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)

    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)

    Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size=-128000;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size=268435456;")

    initialize_routing_schema(conn)

    # Make ETS tables public and named for access by worker pool
    :ets.new(:shard_cache, [:set, :public, :named_table])
    :ets.new(:shard_access, [:ordered_set, :public, :named_table])
    cache_table = :shard_cache
    access_table = :shard_access

    bloom_filters = load_bloom_filters(conn)
    counter = preload_hot_shards(conn, max_size, cache_table, access_table, 0)

    state = %State{routing_conn: conn, cache_table: cache_table, access_table: access_table, access_counts: %{}, bloom_filters: bloom_filters, counter: counter, max_size: max_size, cache_hits: 0, cache_misses: 0}

    Process.send_after(self(), :persist_stats, refresh_interval)
    {:ok, state}
  end

  def handle_info(:persist_stats, state) do
    persist_query_counts(state)
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)
    Process.send_after(self(), :persist_stats, refresh_interval)
    {:noreply, %{state | access_counts: %{}}}
  end

  defp initialize_routing_schema(conn) do
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS shard_metadata (id TEXT PRIMARY KEY, path TEXT NOT NULL, doc_count INTEGER DEFAULT 0, query_count INTEGER DEFAULT 0, last_accessed DATETIME, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, status TEXT DEFAULT 'active', bloom_filter BLOB);")
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS shard_centroids (shard_id TEXT PRIMARY KEY, centroid BLOB NOT NULL, centroid_norm REAL NOT NULL, FOREIGN KEY (shard_id) REFERENCES shard_metadata(id) ON DELETE CASCADE);")
    Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_shard_status_queries ON shard_metadata(status, query_count DESC);")
    Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_shard_accessed ON shard_metadata(last_accessed DESC) WHERE status = 'active';")
    Exqlite.Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS idx_centroid_norm ON shard_centroids(centroid_norm);")
  end

  def find_similar_shards(query_vector, limit, opts \\ []), do: GenServer.call(__MODULE__, {:find_similar, query_vector, limit, opts}, 30_000)
  def reset_state(), do: GenServer.call(__MODULE__, :reset_state)
  def get_cache_state(), do: GenServer.call(__MODULE__, :get_cache_state)
  def update_centroid(shard_id, centroid), do: GenServer.cast(__MODULE__, {:update_centroid, shard_id, centroid})
  def register_shard(shard_info), do: GenServer.cast(__MODULE__, {:register_shard, shard_info})

  def handle_call({:find_similar, query_vector, limit, opts}, _from, state) do
    {shards, cache_hit} = Mosaic.WorkerPool.transaction(:router_pool, fn worker ->
      GenServer.call(worker, {:find_similar, query_vector, limit, opts, state})
    end)
    new_state = if cache_hit, do: %{state | cache_hits: state.cache_hits + 1}, else: %{state | cache_misses: state.cache_misses + 1}
    final_state = update_access_stats(shards, new_state)
    {:reply, {:ok, shards}, final_state}
  end

  def handle_call(:reset_state, _from, state) do
    # Explicitly delete ETS tables by name
    :ets.delete(:shard_cache)
    :ets.delete(:shard_access)
    Exqlite.Sqlite3.close(state.routing_conn)

    routing_db_path = Mosaic.Config.get(:routing_db_path)
    max_size = Mosaic.Config.get(:routing_cache_max_size)

    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)
    initialize_routing_schema(conn)

    # Make ETS tables public and named for access by worker pool
    :ets.new(:shard_cache, [:set, :public, :named_table])
    :ets.new(:shard_access, [:ordered_set, :public, :named_table])
    cache_table = :shard_cache
    access_table = :shard_access

    bloom_filters = load_bloom_filters(conn)
    counter = preload_hot_shards(conn, max_size, cache_table, access_table, 0)

    new_state = %State{routing_conn: conn, cache_table: cache_table, access_table: access_table, access_counts: %{}, bloom_filters: bloom_filters, counter: counter, max_size: max_size, cache_hits: 0, cache_misses: 0}
    {:reply, :ok, new_state}
  end

  def handle_call(:list_all_shards, _from, state) do
    shards = :ets.tab2list(state.cache_table) |> Enum.map(fn {_id, shard} -> shard end)
    {:reply, shards, state}
  end

  def handle_call(:get_cache_state, _from, state) do
    cache_keys = :ets.tab2list(state.cache_table) |> Enum.map(fn {id, _} -> id end) |> Enum.sort()
    access_list = :ets.tab2list(state.access_table) |> Enum.sort()
    {:reply, %{cache_keys: cache_keys, access_list: access_list}, state}
  end

  def handle_cast({:update_centroid, shard_id, centroid}, state) do
    centroid_norm = VectorMath.norm(centroid)
    centroid_blob = :erlang.term_to_binary(centroid)

    Mosaic.DB.execute(state.routing_conn, "INSERT OR REPLACE INTO shard_centroids (shard_id, centroid, centroid_norm) VALUES (?, ?, ?)", [shard_id, centroid_blob, centroid_norm])

    # Update the cached shard if it exists
    case :ets.lookup(state.cache_table, shard_id) do
      [{^shard_id, cached_shard}] ->
        updated_shard = %{cached_shard | centroid: centroid_blob, centroid_norm: centroid_norm}
        :ets.insert(state.cache_table, {shard_id, updated_shard})
      [] -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:register_shard, shard_info}, state) do
    %{id: id, path: path, centroid: centroid, doc_count: doc_count, bloom_filter: bloom} = shard_info
    centroid_norm = VectorMath.norm(centroid)
    centroid_blob = :erlang.term_to_binary(centroid)
    bloom_blob = BloomFilter.to_binary(bloom)

    Mosaic.DB.execute(state.routing_conn, "INSERT OR REPLACE INTO shard_metadata (id, path, doc_count, bloom_filter, updated_at) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)", [id, path, doc_count, bloom_blob])
    Mosaic.DB.execute(state.routing_conn, "INSERT OR REPLACE INTO shard_centroids (shard_id, centroid, centroid_norm) VALUES (?, ?, ?)", [id, centroid_blob, centroid_norm])

    cached_shard = %{id: id, path: path, doc_count: doc_count, query_count: 0, centroid: centroid_blob, centroid_norm: centroid_norm}
    :ets.insert(state.cache_table, {id, cached_shard})
    :ets.insert(state.access_table, {{state.counter, id}, true})
    new_blooms = Map.put(state.bloom_filters, id, bloom)

    {:noreply, %{state | bloom_filters: new_blooms, counter: state.counter + 1}}
  end

  # Public function to be called by ShardRouter.Worker
  # Returns {shards, cache_hit_boolean}
  def do_find_similar(query_vector, limit, opts, current_state) do
    min_similarity = Keyword.get(opts, :min_similarity, Mosaic.Config.get(:min_similarity))
    vector_math_impl = Keyword.get(opts, :vector_math_impl, VectorMath)

    filtered_shards = case Keyword.get(opts, :keywords) do
      nil -> nil
      keywords -> filter_by_bloom(keywords, current_state.bloom_filters)
    end

    p_do_find_similar(query_vector, limit, min_similarity, filtered_shards, vector_math_impl, current_state)
  end

  defp p_do_find_similar(query_vector, limit, min_similarity, filter_ids, vector_math_impl, state) do
    query_norm = vector_math_impl.norm(query_vector)

    candidates = if filter_ids do
      filter_ids
      |> Enum.filter(&(:ets.member(state.cache_table, &1))) # Use table name here
      |> Enum.map(fn id ->
        case :ets.lookup(state.cache_table, id) do # Use table name here
          [{^id, shard}] -> shard
          [] -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      :ets.tab2list(state.cache_table) |> Enum.map(fn {_id, shard} -> shard end) # Use table name here
    end

    cached_shards = candidates |> Enum.map(fn shard ->
      centroid_vector = :erlang.binary_to_term(shard.centroid)
      similarity = vector_math_impl.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)
      Map.put(shard, :similarity, similarity)
    end) |> Enum.filter(&(&1.similarity >= min_similarity))

    if length(cached_shards) >= limit do
      result = Enum.sort_by(cached_shards, & &1.similarity, :desc) |> Enum.take(limit)
      {result, true} # Return shards and cache_hit = true
    else
      db_shards = p_find_similar_db(query_vector, limit, min_similarity, filter_ids, vector_math_impl, state)
      _new_counter = Enum.reduce(db_shards, state.counter, fn shard, cnt -> add_to_cache(shard, cnt, state) end)
      {db_shards, false} # Return shards and cache_hit = false
    end
  end

  defp p_find_similar_db(query_vector, limit, min_similarity, filter_ids, vector_math_impl, state) do
    query_norm = vector_math_impl.norm(query_vector)
    where_clause = if filter_ids, do: "AND sm.id IN (#{Enum.map_join(filter_ids, ",", &"'#{&1}'")})", else: ""

    {:ok, statement} = Exqlite.Sqlite3.prepare(state.routing_conn, "SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm FROM shard_metadata sm JOIN shard_centroids sc ON sm.id = sc.shard_id WHERE sm.status = 'active' #{where_clause} ORDER BY sm.query_count DESC LIMIT 5000")
    Exqlite.Sqlite3.bind(statement, [])

    case Exqlite.Sqlite3.fetch_all(state.routing_conn, statement) do
      {:ok, rows} ->
        rows |> Enum.map(&row_to_shard/1) |> Enum.map(fn shard ->
          centroid_vector = :erlang.binary_to_term(shard.centroid)
          similarity = vector_math_impl.cosine_similarity(query_vector, query_norm, centroid_vector, shard.centroid_norm)
          Map.put(shard, :similarity, similarity)
        end) |> Enum.filter(&(&1.similarity >= min_similarity)) |> Enum.sort_by(& &1.similarity, :desc) |> Enum.take(limit)
      {:error, reason} ->
        Logger.error("Database shard search failed: #{inspect(reason)}")
        []
    end
  end

  defp add_to_cache(shard, counter, state) do
    # Check if shard already exists
    case :ets.lookup(state.cache_table, shard.id) do
      [{_, _}] ->
        # Already cached, just update access
        :ets.match_delete(state.access_table, {{:_, shard.id}, :_})
        :ets.insert(state.access_table, {{counter, shard.id}, true})
        counter + 1
      [] ->
        # Not cached, need to add
        cache_size = :ets.info(state.cache_table, :size)
        if cache_size >= state.max_size do
          case :ets.first(state.access_table) do
            :"$end_of_table" -> :ok
            {old_counter, old_id} ->
              :ets.delete(state.access_table, {old_counter, old_id})
              :ets.delete(state.cache_table, old_id)
          end
        end
        :ets.insert(state.cache_table, {shard.id, shard})
        :ets.insert(state.access_table, {{counter, shard.id}, true})
        counter + 1
    end
  end

  defp filter_by_bloom(keywords, bloom_filters) do
    bloom_filters |> Enum.filter(fn {_shard_id, bloom} -> Enum.all?(keywords, &BloomFilter.member?(bloom, &1)) end) |> Enum.map(fn {shard_id, _bloom} -> shard_id end)
  end

  defp row_to_shard([id, path, doc_count, query_count, centroid, centroid_norm]) do
    %{id: id, path: path, doc_count: doc_count, query_count: query_count, centroid: centroid, centroid_norm: centroid_norm}
  end

  defp load_bloom_filters(conn) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT id, bloom_filter FROM shard_metadata WHERE status = 'active' AND bloom_filter IS NOT NULL")
    Exqlite.Sqlite3.bind(statement, [])
    case Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, rows} -> rows |> Enum.map(fn [id, bloom_blob] -> {id, BloomFilter.from_binary(bloom_blob)} end) |> Map.new()
      _ -> %{}
    end
  end

  defp preload_hot_shards(conn, limit, cache_table, access_table, initial_counter) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm FROM shard_metadata sm JOIN shard_centroids sc ON sm.id = sc.shard_id WHERE sm.status = 'active' ORDER BY sm.query_count DESC, sm.last_accessed DESC LIMIT ?")
    Exqlite.Sqlite3.bind(statement, [limit])
    case Exqlite.Sqlite3.fetch_all(conn, statement) do
      {:ok, rows} ->
        rows |> Enum.with_index(initial_counter) |> Enum.reduce(initial_counter, fn {row, counter}, _acc ->
          shard = row_to_shard(row)
          :ets.insert(cache_table, {shard.id, shard})
          :ets.insert(access_table, {{counter, shard.id}, true})
          counter + 1
        end)
      _ -> initial_counter
    end
  end

  defp update_access_stats(shards, state) do
    new_counts = Enum.reduce(shards, state.access_counts, fn shard, counts -> Map.update(counts, shard.id, 1, &(&1 + 1)) end)

    new_counter = Enum.reduce(shards, state.counter, fn shard, cnt ->
      shard_id = shard.id
      case :ets.lookup(state.cache_table, shard_id) do
        [{_, _}] ->
          :ets.match_delete(state.access_table, {{:_, shard_id}, :_})
          :ets.insert(state.access_table, {{cnt, shard_id}, true})
          cnt + 1
        [] -> cnt
      end
    end)

    %{state | access_counts: new_counts, counter: new_counter}
  end

  defp persist_query_counts(state) do
    Enum.each(state.access_counts, fn {shard_id, count} ->
      {:ok, statement} = Exqlite.Sqlite3.prepare(state.routing_conn, "UPDATE shard_metadata SET query_count = query_count + ?, last_accessed = CURRENT_TIMESTAMP WHERE id = ?")
      Exqlite.Sqlite3.bind(statement, [count, shard_id])
      Exqlite.Sqlite3.step(state.routing_conn, statement)
    end)
  end
end

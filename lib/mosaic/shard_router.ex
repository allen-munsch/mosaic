defmodule Mosaic.ShardRouter do
  use GenServer
  require Logger
  @behaviour Mosaic.Index.Router # Implement the new router behaviour

  defmodule State do
    defstruct [
      :routing_conn,
      :cache_table,
      :access_table,
      :access_counts,
      :bloom_filters,
      :counter,
      :max_size,
      :cache_hits,
      :cache_misses
    ]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    routing_db_path = Mosaic.Config.get(:routing_db_path)
    max_size = Mosaic.Config.get(:routing_cache_max_size)
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)

    File.mkdir_p!(Path.dirname(routing_db_path))
    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)

    Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size=-128000;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY;")
    Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size=268435456;")

    initialize_routing_schema(conn)

    :ets.new(:shard_cache, [:set, :public, :named_table])
    :ets.new(:shard_access, [:ordered_set, :public, :named_table])
    cache_table = :shard_cache
    access_table = :shard_access

    bloom_filters = load_bloom_filters(conn)
    counter = preload_hot_shards(conn, max_size, cache_table, access_table, 0)

    state = %State{
      routing_conn: conn,
      cache_table: cache_table,
      access_table: access_table,
      access_counts: %{},
      bloom_filters: bloom_filters,
      counter: counter,
      max_size: max_size,
      cache_hits: 0,
      cache_misses: 0
    }

    Process.send_after(self(), :persist_stats, refresh_interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:persist_stats, state) do
    persist_query_counts(state)
    refresh_interval = Mosaic.Config.get(:routing_cache_refresh_interval_ms)
    Process.send_after(self(), :persist_stats, refresh_interval)
    {:noreply, %{state | access_counts: %{}}}
  end

  defp initialize_routing_schema(conn) do
    Mosaic.DB.execute(conn, """
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

    Mosaic.DB.execute(conn, """
      CREATE TABLE IF NOT EXISTS shard_centroids (
        shard_id TEXT,
        level TEXT,
        centroid BLOB NOT NULL,
        centroid_norm REAL NOT NULL,
        PRIMARY KEY (shard_id, level),
        FOREIGN KEY (shard_id) REFERENCES shard_metadata(id) ON DELETE CASCADE
      );
    """)

    Mosaic.DB.execute(
      conn,
      "CREATE INDEX IF NOT EXISTS idx_shard_status_queries ON shard_metadata(status, query_count DESC);"
    )

    Mosaic.DB.execute(
      conn,
      "CREATE INDEX IF NOT EXISTS idx_centroids_level ON shard_centroids(level);"
    )
  end

  # Public API for Strategies
  def find_similar_shards_sync(query_vector, limit, opts \\ []),
    do: GenServer.call(__MODULE__, {:do_find_similar, query_vector, limit, opts}, 30_000)
  
  def route_insert_to_shard(embedding),
    do: GenServer.call(__MODULE__, {:route_insert, embedding})

  @impl true
  def route_query(query_embedding, opts) do
    {:ok, find_similar_shards_sync(query_embedding, Keyword.get(opts, :limit, Mosaic.Config.get(:default_shard_limit)), opts)}
  end

  @impl true
  def route_insert(_embedding) do
    # For centroid strategy, this might return the active shard for insertion
    # For now, return a dummy path or delegate to a helper
    {:ok, "path/to/shard.db"}
  end

  @impl true
  def rebalance(opts) do
    Logger.info("Rebalancing shards (Centroid strategy): #{inspect(opts)}")
    :ok
  end

  def reset_state(), do: GenServer.call(__MODULE__, :reset_state)
  def get_cache_state(), do: GenServer.call(__MODULE__, :get_cache_state)
  def get_routing_conn(), do: GenServer.call(__MODULE__, :get_routing_conn)

  def update_centroid(shard_id, centroid),
    do: GenServer.cast(__MODULE__, {:update_centroid, shard_id, centroid})

  def register_shard(shard_info), do: GenServer.call(__MODULE__, {:register_shard, shard_info})
  def list_all_shards, do: GenServer.call(__MODULE__, :list_all_shards)
  def list_all_shard_paths, do: GenServer.call(__MODULE__, :list_all_shard_paths)

  @impl true
  def handle_call(:get_routing_conn, _from, state) do
    {:reply, state.routing_conn, state}
  end

  def handle_call({:do_find_similar, query_vector, limit, opts}, _from, state) do
    {shards, cache_hit} =
      Mosaic.WorkerPool.transaction(:router_pool, fn worker ->
        GenServer.call(worker, {:do_find_similar, query_vector, limit, opts, state})
      end)

    new_state =
      if cache_hit,
        do: %{state | cache_hits: state.cache_hits + 1},
        else: %{state | cache_misses: state.cache_misses + 1}

    final_state = update_access_stats(shards, new_state)
    {:reply, shards, final_state}
  end

  def handle_call(:reset_state, _from, state) do
    # Close existing connection if open
    if state.routing_conn, do: Exqlite.Sqlite3.close(state.routing_conn)

    routing_db_path = Mosaic.Config.get(:routing_db_path)

    # Ensure parent directory exists
    routing_db_path |> Path.dirname() |> File.mkdir_p!()
    if File.exists?(routing_db_path), do: File.rm!(routing_db_path)

    case Exqlite.Sqlite3.open(routing_db_path) do
      {:ok, conn} ->
        initialize_routing_schema(conn)
        # Reset ETS tables and other state variables
        :ets.delete(:shard_cache)
        :ets.delete(:shard_access)
        :ets.new(:shard_cache, [:set, :public, :named_table])
        :ets.new(:shard_access, [:ordered_set, :public, :named_table])

        new_state = %{
          state
          | routing_conn: conn,
            cache_table: :shard_cache,
            access_table: :shard_access,
            access_counts: %{},
            bloom_filters: %{},
            counter: 0,
            cache_hits: 0,
            cache_misses: 0
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to reset ShardRouter state: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_all_shards, _from, state) do
    shards = :ets.tab2list(state.cache_table) |> Enum.map(fn {_id, shard} -> shard end)
    {:reply, shards, state}
  end

  def handle_call(:list_all_shard_paths, _from, state) do
    {:ok, rows} = Mosaic.DB.query(state.routing_conn, "SELECT path FROM shard_metadata WHERE status = 'active'", [])
    paths = Enum.map(rows, fn [path] -> path end)
    {:reply, paths, state}
  end

  def handle_call(:get_cache_state, _from, state) do
    cache_keys = :ets.tab2list(state.cache_table) |> Enum.map(fn {id, _} -> id end) |> Enum.sort()
    access_list = :ets.tab2list(state.access_table) |> Enum.sort()
    {:reply, %{cache_keys: cache_keys, access_list: access_list}, state}
  end

  def handle_call({:register_shard, shard_info}, _from, state) do
    # Insert into routing DB
    Mosaic.DB.execute(state.routing_conn, """
      INSERT OR REPLACE INTO shard_metadata (id, path, doc_count, bloom_filter)
      VALUES (?, ?, ?, ?)
    """, [shard_info.id, shard_info.path, shard_info.doc_count, :erlang.term_to_binary(shard_info.bloom_filter)])

    # Insert centroids for each level
    Enum.each(shard_info.centroids, fn {level, centroid} ->
      blob = :erlang.term_to_binary(centroid)
      norm = VectorMath.norm(centroid)
      Mosaic.DB.execute(state.routing_conn, """
        INSERT OR REPLACE INTO shard_centroids (shard_id, level, centroid, centroid_norm)
        VALUES (?, ?, ?, ?)
      """, [shard_info.id, Atom.to_string(level), blob, norm])
    end)

    # Also cache in ETS
    :ets.insert(state.cache_table, {shard_info.id, shard_info})

    {:reply, :ok, state}
  end

  def handle_call({:route_insert, _embedding}, _from, state) do
    # This is a placeholder for actual routing logic that determines which shard to insert into.
    # For the centroid strategy, it might return the currently active shard.
    # For now, it simply finds the least full active shard.
    active_shards = list_all_shards_from_db(state.routing_conn)
    case Enum.min_by(active_shards, & &1.doc_count, fn -> nil end) do
      nil ->
        {:error, :no_active_shards}
      shard ->
        {:ok, shard.path}
    end
  end

  defp list_all_shards_from_db(conn) do
    case Mosaic.DB.query(conn, "SELECT id, path, doc_count FROM shard_metadata WHERE status = 'active'", []) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, path, doc_count] -> %{id: id, path: path, doc_count: doc_count} end)
      {:error, _} ->
        []
    end
  end

  @impl true
  def handle_cast({:update_centroid, shard_id, centroid}, state) do
    centroid_norm = VectorMath.norm(centroid)
    centroid_blob = :erlang.term_to_binary(centroid)

    Mosaic.DB.execute(
      state.routing_conn,
      "INSERT OR REPLACE INTO shard_centroids (shard_id, level, centroid, centroid_norm) VALUES (?, 'paragraph', ?, ?)",
      [shard_id, centroid_blob, centroid_norm]
    )

    case :ets.lookup(state.cache_table, shard_id) do
      [{_, cached_shard}] ->
        updated_shard = %{cached_shard | centroid: centroid_blob, centroid_norm: centroid_norm}
        :ets.insert(state.cache_table, {shard_id, updated_shard})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @spec do_find_similar(any(), any(), keyword(), any()) :: {list(), false}
  def do_find_similar(query_vector, limit, opts, current_state) do
    min_similarity = Keyword.get(opts, :min_similarity, Mosaic.Config.get(:min_similarity))
    level = Keyword.get(opts, :level, :paragraph)
    vector_math_impl = Keyword.get(opts, :vector_math_impl, VectorMath)
    query_terms = Keyword.get(opts, :query_terms, [])

    candidates = fetch_shards_for_level(current_state.routing_conn, level)

    filtered =
      if Enum.empty?(query_terms) do
        candidates
      else
        Enum.filter(candidates, fn shard ->
          case Map.get(current_state.bloom_filters, shard.id) do
            nil -> true
            bloom -> Enum.any?(query_terms, &BloomFilter.member?(bloom, String.downcase(&1)))
          end
        end)
      end

    if Enum.empty?(filtered) do
      {[], false}
    else
      query_norm = vector_math_impl.norm(query_vector)

      scored =
        filtered
        |> Enum.map(fn shard ->
          centroid_vector = :erlang.binary_to_term(shard.centroid)

          similarity =
            vector_math_impl.cosine_similarity(
              query_vector,
              query_norm,
              centroid_vector,
              shard.centroid_norm
            )

          Map.put(shard, :similarity, similarity)
        end)
        |> Enum.filter(&(&1.similarity >= min_similarity))
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      {scored, false}
    end
  end

  defp fetch_shards_for_level(conn, level) do
    case Mosaic.DB.query(
           conn,
           """
             SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm
             FROM shard_metadata sm
             JOIN shard_centroids sc ON sm.id = sc.shard_id
             WHERE sm.status = 'active' AND sc.level = ?
             ORDER BY sm.query_count DESC
             LIMIT 1000
           """,
           [Atom.to_string(level)]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, path, doc_count, query_count, centroid, centroid_norm] ->
          %{
            id: id,
            path: path,
            doc_count: doc_count,
            query_count: query_count,
            centroid: centroid,
            centroid_norm: centroid_norm
          }
        end)

      {:error, err} ->
        Logger.error("Error fetching shards for level #{level}: #{inspect(err)}")
        []
    end
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
    case Mosaic.DB.query(
           conn,
           "SELECT id, bloom_filter FROM shard_metadata WHERE status = 'active' AND bloom_filter IS NOT NULL",
           []
         ) do
      {:ok, rows} ->
        rows
        |> Enum.map(fn [id, bloom_blob] -> {id, :erlang.binary_to_term(bloom_blob)} end)
        |> Map.new()

      {:error, err} ->
        Logger.error("Error loading bloom filters: #{inspect(err)}")
        %{}
    end
  end

  defp preload_hot_shards(conn, limit, cache_table, access_table, initial_counter) do
    case Mosaic.DB.query(
           conn,
           "SELECT sm.id, sm.path, sm.doc_count, sm.query_count, sc.centroid, sc.centroid_norm FROM shard_metadata sm LEFT JOIN shard_centroids sc ON sm.id = sc.shard_id WHERE sm.status = 'active' ORDER BY sm.query_count DESC, sm.last_accessed DESC LIMIT ?",
           [limit]
         ) do
      {:ok, rows} ->
        rows
        |> Enum.filter(fn row -> length(row) == 6 and Enum.at(row, 4) != nil end)
        |> Enum.with_index(initial_counter)
        |> Enum.reduce(initial_counter, fn {row, counter}, _acc ->
          shard = row_to_shard(row)
          :ets.insert(cache_table, {shard.id, shard})
          :ets.insert(access_table, {{counter, shard.id}, true})
          counter + 1
        end)

      {:error, err} ->
        Logger.error("Error preloading hot shards: #{inspect(err)}")
        initial_counter
    end
  end

  defp update_access_stats(shards, state) do
    new_counts =
      Enum.reduce(shards, state.access_counts, fn shard, counts ->
        Map.update(counts, shard.id, 1, &(&1 + 1))
      end)

    new_counter =
      Enum.reduce(shards, state.counter, fn shard, cnt ->
        shard_id = shard.id

        case :ets.lookup(state.cache_table, shard_id) do
          [{_, _}] ->
            :ets.match_delete(state.access_table, {{:_, shard_id}, :_})
            :ets.insert(state.access_table, {{cnt, shard_id}, true})
            cnt + 1

          [] ->
            cnt
        end
      end)

    %{state | access_counts: new_counts, counter: new_counter}
  end

  defp persist_query_counts(state) do
    Enum.each(state.access_counts, fn {shard_id, count} ->
      Mosaic.DB.execute(
        state.routing_conn,
        "UPDATE shard_metadata SET query_count = query_count + ?, last_accessed = CURRENT_TIMESTAMP WHERE id = ?",
        [count, shard_id]
      )
    end)
  end
end

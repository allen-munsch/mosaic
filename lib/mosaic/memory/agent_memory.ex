defmodule Mosaic.Memory.AgentMemory do
  @moduledoc """
  Persistent agent memory system with graph-structured recall and automatic consolidation.

  This is the #1 killer feature for AI agent economies. Every agent framework
  (LangChain, CrewAI, AutoGen, etc.) reimplements memory poorly. MosaicDB provides:

  1. **Persistent, cross-session** memory — survives restarts via SQLite shards
  2. **Graph-structured** memories — facts are connected (this relates to that)
  3. **Automatic consolidation** — episodic memories summarized into semantic facts
  4. **Handle compression** — token-efficient retrieval via handle registry
  5. **Hybrid retrieval** — vector + graph traversal for context-aware recall

  ## Memory Types

  - `:episodic`  — what happened (timestamped events, conversations)
  - `:semantic`  — facts learned (user preferences, domain knowledge)
  - `:procedural` — how-to patterns (workflows, recipes, successful strategies)

  ## Usage

      # Remember something
      Mosaic.Memory.AgentMemory.remember("session_abc", "User prefers dark mode",
        type: :semantic, tags: ["preferences", "ui"])

      # Recall with hybrid retrieval
      memories = Mosaic.Memory.AgentMemory.recall("session_abc", "user preferences",
        types: [:semantic, :episodic], limit: 5)

      # Consolidate old episodic memories into semantic facts
      Mosaic.Memory.AgentMemory.consolidate("session_abc",
        older_than: :timer.hours(24), summarizer: &MyApp.LLM.summarize/1)

      # Forget (with soft delete)
      Mosaic.Memory.AgentMemory.forget("session_abc", memory_id)

      # Get memory stats
      stats = Mosaic.Memory.AgentMemory.stats("session_abc")
  """

  require Logger

  alias Mosaic.Vector.CascadedSearch
  alias Mosaic.HandleRegistry

  @type memory_type :: :episodic | :semantic | :procedural

  @type memory :: %{
    id: String.t(),
    session_id: String.t(),
    type: memory_type(),
    content: String.t(),
    embedding: [float()],
    metadata: map(),
    tags: [String.t()],
    importance: float(),
    access_count: integer(),
    created_at: String.t(),
    last_accessed_at: String.t(),
    consolidated_from: [String.t()] | nil,
    consolidation_of: String.t() | nil
  }

  @default_importance 0.5
  @default_limit 10

  @doc """
  Store a new memory for an agent session.

  Returns the memory with a compact handle stub for LLM context efficiency.

  Options:
    - `:type` — `:episodic`, `:semantic`, or `:procedural` (default: `:episodic`)
    - `:tags` — list of string tags for categorization
    - `:importance` — float 0.0-1.0 (default: 0.5)
    - `:metadata` — arbitrary map for additional context
    - `:related_to` — list of existing memory IDs to create graph edges to
  """
  def remember(session_id, content, opts \\ []) when is_binary(session_id) and is_binary(content) do
    type = Keyword.get(opts, :type, :episodic)
    tags = Keyword.get(opts, :tags, [])
    importance = Keyword.get(opts, :importance, @default_importance)
    metadata = Keyword.get(opts, :metadata, %{})
    related_to = Keyword.get(opts, :related_to, [])

    memory_id = generate_id()
    embedding = Mosaic.EmbeddingService.encode(content)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    memory = %{
      id: memory_id,
      session_id: session_id,
      type: type,
      content: content,
      embedding: embedding,
      metadata: metadata,
      tags: tags,
      importance: importance,
      access_count: 0,
      created_at: now,
      last_accessed_at: now,
      consolidated_from: nil,
      consolidation_of: nil
    }

    with {:ok, _} <- persist_memory(memory) do
      # Create graph edges to related memories
      if related_to != [] do
        create_relations(memory_id, related_to, "relates_to")
      end

      # Store compact stub for LLM efficiency
      stub = HandleRegistry.store("mem_#{session_id}_#{memory_id}", [memory],
        ttl: 86_400 * 30)

      Logger.debug("Memory stored: #{memory_id} (#{type}) in session #{session_id}")
      {:ok, memory, stub}
    end
  end

  @doc """
  Recall memories for a session using hybrid retrieval.

  Combines vector similarity search with graph-based context expansion.
  Results ranked by: similarity * importance * recency * access_frequency.

  Options:
    - `:types` — filter to specific memory types (default: all)
    - `:limit` — max results (default: 10)
    - `:min_similarity` — cosine similarity floor (default: 0.1)
    - `:expand_context` — also retrieve related memories via graph edges
    - `:order_by` — sort field (default: `:relevance`)
    - `:since` — ISO8601 timestamp, only memories after this
  """
  def recall(session_id, query, opts \\ []) when is_binary(session_id) and is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    types = Keyword.get(opts, :types)
    min_sim = Keyword.get(opts, :min_similarity, 0.1)
    expand_context = Keyword.get(opts, :expand_context, true)

    # Build SQL filters
    type_filter = build_type_filter(types)

    # Vector search with session + type filters
    results = Mosaic.Memory.AgentMemory.query_memories(
      query, session_id,
      limit: limit * 2,
      min_similarity: min_sim,
      type_filter: type_filter
    )

    # Update access counts
    results = Enum.map(results, fn mem ->
      bump_access_count(mem.id)
      %{mem | access_count: mem.access_count + 1}
    end)

    # Expand context via graph edges
    results = if expand_context do
      Enum.flat_map(results, fn mem ->
        related = get_related_memories(mem.id, depth: 1)
        [%{mem | related: related}]
      end)
    else
      results
    end

    # Score and rank
    scored = rank_memories(results, query)
    |> Enum.take(limit)

    # Store as handle for token efficiency
    handle = HandleRegistry.store("recall_#{session_id}_#{sanitize(query)}", scored,
      ttl: 3600)

    {:ok, scored, handle}
  end

  @doc """
  Consolidate old episodic memories into compact semantic facts.

  Takes all episodic memories older than `older_than` and passes them
  through a summarizer function to produce condensed semantic memories.
  The original episodic memories are soft-deleted (marked as consolidated).

  Options:
    - `:older_than` — time in milliseconds (default: 24 hours)
    - `:summarizer` — function that takes list of memory maps and returns summary string
    - `:min_memories` — minimum memories to trigger consolidation (default: 10)
  """
  def consolidate(session_id, opts \\ []) do
    older_than_ms = Keyword.get(opts, :older_than, 86_400_000) # 24h default
    summarizer = Keyword.get(opts, :summarizer, &default_summarizer/1)
    min_memories = Keyword.get(opts, :min_memories, 10)

    cutoff = DateTime.utc_now()
    |> DateTime.add(-trunc(older_than_ms / 1000), :second)
    |> DateTime.to_iso8601()

    with {:ok, memories} <- get_episodic_memories(session_id, cutoff) do
      if length(memories) < min_memories do
        {:ok, %{consolidated: 0, reason: :not_enough_memories, have: length(memories), need: min_memories}}
      else
        # Group memories by tag/topic for better consolidation
        grouped = group_by_topic(memories)

        results = Enum.map(grouped, fn {topic, topic_memories} ->
          summary = summarizer.(topic_memories)
          source_ids = Enum.map(topic_memories, & &1.id)

          # Store the consolidated semantic memory
          {:ok, consolidated_mem, _stub} = remember(session_id, summary,
            type: :semantic,
            tags: [topic | ["consolidated"]],
            importance: average_importance(topic_memories),
            metadata: %{consolidated_from_count: length(topic_memories)}
          )

          # Soft-delete the originals
          Enum.each(source_ids, &mark_consolidated(&1, consolidated_mem.id))

          %{topic: topic, source_count: length(source_ids), consolidated_id: consolidated_mem.id}
        end)

        {:ok, %{consolidated: length(memories), groups: length(results), results: results}}
      end
    end
  end

  @doc """
  Soft-delete a memory. Retains the embedding and metadata but marks it as forgotten.
  """
  def forget(session_id, memory_id) when is_binary(session_id) and is_binary(memory_id) do
    with {:ok, conn} <- get_memory_conn() do
      Mosaic.DB.execute(conn,
        "UPDATE memories SET forgotten = 1, forgotten_at = datetime('now') WHERE id = ? AND session_id = ?",
        [memory_id, session_id])
      release_conn(conn)
      :ok
    end
  end

  @doc """
  Hard-delete a memory and its embedding vectors.
  """
  def delete(session_id, memory_id) when is_binary(session_id) and is_binary(memory_id) do
    with {:ok, conn} <- get_memory_conn() do
      Mosaic.DB.execute(conn, "DELETE FROM memories WHERE id = ? AND session_id = ?",
        [memory_id, session_id])
      Mosaic.DB.execute(conn, "DELETE FROM memory_edges WHERE source_id = ? OR target_id = ?",
        [memory_id, memory_id])
      release_conn(conn)
      :ok
    end
  end

  @doc """
  Get statistics about memory usage for a session.
  """
  def stats(session_id) when is_binary(session_id) do
    with {:ok, conn} <- get_memory_conn() do
      {:ok, [[total]]} = Mosaic.DB.query(conn,
        "SELECT COUNT(*) FROM memories WHERE session_id = ? AND forgotten = 0", [session_id])

      {:ok, [[episodic]]} = Mosaic.DB.query(conn,
        "SELECT COUNT(*) FROM memories WHERE session_id = ? AND type = 'episodic' AND forgotten = 0", [session_id])

      {:ok, [[semantic]]} = Mosaic.DB.query(conn,
        "SELECT COUNT(*) FROM memories WHERE session_id = ? AND type = 'semantic' AND forgotten = 0", [session_id])

      {:ok, [[procedural]]} = Mosaic.DB.query(conn,
        "SELECT COUNT(*) FROM memories WHERE session_id = ? AND type = 'procedural' AND forgotten = 0", [session_id])

      {:ok, [[consolidated]]} = Mosaic.DB.query(conn,
        "SELECT COUNT(*) FROM memories WHERE session_id = ? AND consolidated_from IS NOT NULL", [session_id])

      release_conn(conn)

      {:ok, %{
        total: total,
        episodic: episodic,
        semantic: semantic,
        procedural: procedural,
        consolidated: consolidated,
        avg_importance: :todo
      }}
    end
  end

  @doc """
  Search memories across all sessions (admin/analytics use).
  """
  def search_all(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    Mosaic.Memory.AgentMemory.query_memories(query, nil,
      limit: limit,
      min_similarity: Keyword.get(opts, :min_similarity, 0.3))
  end

  # ── Public: Called by AgentMemory ─────────────────────────

  def query_memories(query_text, session_id, opts) do
    embedding = Mosaic.EmbeddingService.encode(query_text)
    limit = Keyword.get(opts, :limit, 20)
    min_sim = Keyword.get(opts, :min_similarity, 0.1)
    type_filter = Keyword.get(opts, :type_filter, "")

    shard_path = memory_db_path()

    result = Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      embedding_json = Jason.encode!(embedding)
      session_clause = if session_id, do: "AND m.session_id = ?", else: ""
      params = if session_id do
        [embedding_json, 1.0 - min_sim, session_id, limit]
      else
        [embedding_json, 1.0 - min_sim, limit]
      end

      sql = """
      SELECT m.id, m.session_id, m.type, m.content, m.metadata, m.tags,
             m.importance, m.access_count, m.created_at, m.last_accessed_at,
             vec_distance_cosine(v.embedding, ?) as distance
      FROM vec_memories v
      JOIN memories m ON m.id = v.id
      WHERE vec_distance_cosine(v.embedding, ?) < ?
        AND m.forgotten = 0
        #{session_clause}
        #{type_filter}
      ORDER BY distance ASC
      LIMIT ?
      """

      case Mosaic.DB.query(conn, sql, params) do
        {:ok, rows} ->
          memories = Enum.map(rows, fn [id, sid, type, content, metadata, tags,
                                         importance, access_count, created_at, last_accessed_at, distance] ->
            %{
              id: id,
              session_id: sid,
              type: String.to_atom(type),
              content: content,
              metadata: safe_decode_json(metadata),
              tags: safe_decode_json_list(tags),
              importance: importance || 0.5,
              access_count: access_count || 0,
              created_at: created_at,
              last_accessed_at: last_accessed_at,
              similarity: Float.round(1.0 - to_float(distance), 4)
            }
          end)
          {:ok, memories}

        {:error, reason} -> {:error, reason}
      end
    end)

    case result do
      {:ok, {:ok, memories}} -> memories
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp persist_memory(memory) do
    shard_path = memory_db_path()

    case Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      # Insert into memories table
      Mosaic.DB.execute(conn, """
        INSERT OR REPLACE INTO memories (id, session_id, type, content, metadata, tags,
          importance, access_count, created_at, last_accessed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        memory.id, memory.session_id, Atom.to_string(memory.type),
        memory.content, Jason.encode!(memory.metadata), Jason.encode!(memory.tags),
        memory.importance, memory.access_count,
        memory.created_at, memory.last_accessed_at
      ])

      # Insert embedding into vec_memories
      embedding_json = Jason.encode!(memory.embedding)
      Mosaic.DB.execute(conn,
        "INSERT OR REPLACE INTO vec_memories (id, embedding) VALUES (?, ?)",
        [memory.id, embedding_json])

      {:ok, memory.id}
    end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_relations(source_id, target_ids, relation_type) do
    shard_path = memory_db_path()
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      Enum.each(target_ids, fn target_id ->
        edge_id = "mem_edge_#{source_id}_#{target_id}_#{System.unique_integer()}"
        Mosaic.DB.execute(conn,
          "INSERT OR IGNORE INTO memory_edges (id, source_id, target_id, type) VALUES (?, ?, ?, ?)",
          [edge_id, source_id, target_id, relation_type])
      end)
      :ok
    end)
  end

  defp get_related_memories(memory_id, opts) do
    depth = Keyword.get(opts, :depth, 1)
    shard_path = memory_db_path()

    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      sql = """
      WITH RECURSIVE related(d, node_id) AS (
        SELECT 0, ?
        UNION
        SELECT r.d + 1, e.target_id FROM related r
        JOIN memory_edges e ON e.source_id = r.node_id WHERE r.d < ?
        UNION
        SELECT r.d + 1, e.source_id FROM related r
        JOIN memory_edges e ON e.target_id = r.node_id WHERE r.d < ?
      )
      SELECT DISTINCT m.id, m.content, m.type, m.importance, r.d as depth
      FROM related r
      JOIN memories m ON m.id = r.node_id
      WHERE r.d > 0 AND m.forgotten = 0
      ORDER BY r.d, m.importance DESC
      LIMIT 10
      """

      case Mosaic.DB.query(conn, sql, [memory_id, depth, depth]) do
        {:ok, rows} ->
          Enum.map(rows, fn [id, content, type, importance, depth] ->
            %{id: id, content: String.slice(content, 0, 200), type: type,
              importance: importance, depth: depth}
          end)

        _ -> []
      end
    end)
    |> case do
      {:ok, result} -> result
      _ -> []
    end
  end

  defp get_episodic_memories(session_id, cutoff) do
    shard_path = memory_db_path()
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      sql = """
      SELECT id, content, type, metadata, tags, importance, created_at
      FROM memories
      WHERE session_id = ? AND type = 'episodic' AND created_at < ? AND forgotten = 0
        AND consolidation_of IS NULL
      ORDER BY created_at ASC
      """
      case Mosaic.DB.query(conn, sql, [session_id, cutoff]) do
        {:ok, rows} ->
          memories = Enum.map(rows, fn [id, content, type, metadata, tags, importance, created_at] ->
            %{
              id: id, content: content, type: type,
              metadata: safe_decode_json(metadata),
              tags: safe_decode_json_list(tags),
              importance: importance, created_at: created_at
            }
          end)
          {:ok, memories}
        err -> err
      end
    end)
    |> case do
      {:ok, result} -> result
      error -> error
    end
  end

  defp mark_consolidated(memory_id, consolidated_into_id) do
    shard_path = memory_db_path()
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      Mosaic.DB.execute(conn,
        "UPDATE memories SET consolidation_of = ?, consolidated_at = datetime('now') WHERE id = ?",
        [consolidated_into_id, memory_id])
      :ok
    end)
  end

  defp bump_access_count(memory_id) do
    shard_path = memory_db_path()
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      Mosaic.DB.execute(conn,
        "UPDATE memories SET access_count = access_count + 1, last_accessed_at = datetime('now') WHERE id = ?",
        [memory_id])
      :ok
    end)
  end

  defp rank_memories(memories, query) do
    # Score: similarity * importance * recency_factor * access_factor
    now = DateTime.utc_now() |> DateTime.to_unix()

    memories
    |> Enum.map(fn mem ->
      recency_factor = recency_score(mem, now)
      score = (mem.similarity || 0.5) * mem.importance * recency_factor *
              (1.0 + :math.log(1 + mem.access_count) / 10.0)

      Map.put(mem, :score, Float.round(score, 4))
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp recency_score(mem, now) do
    case DateTime.from_iso8601(mem.created_at) do
      {:ok, dt, _} ->
        age_hours = (now - DateTime.to_unix(dt)) / 3600
        1.0 / (1.0 + age_hours / 168)  # half-life: ~1 week

      _ -> 0.5
    end
  end

  defp group_by_topic(memories) do
    # Simple tag-based grouping with fallback to single group
    grouped = Enum.group_by(memories, fn mem ->
      case mem.tags do
        [] -> "general"
        tags -> hd(tags)
      end
    end)

    if map_size(grouped) == 0, do: %{"general" => memories}, else: grouped
  end

  defp average_importance(memories) do
    if memories == [] do
      @default_importance
    else
      avg = Enum.sum(Enum.map(memories, & &1.importance)) / length(memories)
      Float.round(avg, 3)
    end
  end

  defp default_summarizer(memories) do
    # Simple concatenation-based summarizer when no LLM is provided
    items = memories
    |> Enum.map(fn m -> "- #{String.slice(m.content, 0, 200)}" end)
    |> Enum.take(20)

    "Consolidated from #{length(memories)} memories:\n" <> Enum.join(items, "\n")
  end

  defp build_type_filter(nil), do: ""
  defp build_type_filter(types) when is_list(types) do
    type_strs = Enum.map(types, fn t -> "'#{t}'" end) |> Enum.join(", ")
    "AND m.type IN (#{type_strs})"
  end

  defp memory_db_path do
    Mosaic.Config.get(:memory_db_path, Path.join(Mosaic.Config.get(:storage_path), "agent_memory.db"))
  end

  defp get_memory_conn do
    path = memory_db_path()
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    ensure_schema()
    Mosaic.ConnectionPool.checkout(path)
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(memory_db_path(), conn)
  end

  defp ensure_schema do
    path = memory_db_path()
    unless Process.get(:memory_schema_ensured) do
      Process.put(:memory_schema_ensured, true)
      Mosaic.ConnectionPool.scoped_checkout(path, fn conn ->
        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS memories (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'episodic',
            content TEXT NOT NULL,
            metadata JSON,
            tags JSON,
            importance REAL DEFAULT 0.5,
            access_count INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now')),
            last_accessed_at TEXT DEFAULT (datetime('now')),
            forgotten INTEGER DEFAULT 0,
            forgotten_at TEXT,
            consolidation_of TEXT,
            consolidated_at TEXT
          );
        """)

        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS memory_edges (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'relates_to',
            weight REAL DEFAULT 1.0,
            created_at TEXT DEFAULT (datetime('now')),
            FOREIGN KEY (source_id) REFERENCES memories(id),
            FOREIGN KEY (target_id) REFERENCES memories(id)
          );
        """)

        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id, forgotten);")
        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_memories_type ON memories(type, forgotten);")
        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at);")
        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_memory_edges_source ON memory_edges(source_id);")
        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_memory_edges_target ON memory_edges(target_id);")

        # Vec table for memory embeddings
        Mosaic.DB.execute(conn, """
          CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
            id TEXT PRIMARY KEY,
            embedding float[384]
          );
        """)

        :ok
      end)
    end
  end

  defp generate_id do
    "mem_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp sanitize(text), do: String.slice(text, 0, 40) |> String.replace(~r/[^a-z0-9]/i, "_")

  defp safe_decode_json(nil), do: %{}
  defp safe_decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
  defp safe_decode_json(map) when is_map(map), do: map

  defp safe_decode_json_list(nil), do: []
  defp safe_decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
  defp safe_decode_json_list(list) when is_list(list), do: list

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_number(v), do: v * 1.0
  defp to_float(_), do: 0.0
end

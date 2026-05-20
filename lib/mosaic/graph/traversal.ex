defmodule Mosaic.Graph.Traversal do
  @moduledoc """
  Graph traversals via SQLite recursive CTEs, federated across shards.

  Provides the graph navigation primitives that Matryoshka's lattice-mcp
  calls into for persistent code graph operations. Matryoshka handles the
  LLM reasoning loop and S-expression evaluation; MosaicDB handles the
  data — graph traversals that survive restarts and scale across shards.

  ## Edge types

    - `calls`       — function/method call relationship
    - `extends`     — class/trait inheritance
    - `implements`  — interface/protocol implementation
    - `imports`     — module import / alias / require
    - `contains`    — structural containment (module → function)
    - `references`  — variable/type reference

  ## Usage

      iex> Traversal.callers("Mosaic.QueryEngine.execute_query/2", depth: 2)
      [%{depth: 1, name: "Mosaic.Search.perform_search/2", ...}, ...]

      iex> Traversal.ancestors("Mosaic.Index.Strategy.HNSW")
      [%{depth: 1, name: "Mosaic.Index.Strategy", ...}]

      iex> Traversal.neighborhood("handle_error", depth: 2)
      %{nodes: [...], edges: [...]}
  """

  @max_depth 20

  # ── Incoming relationships ───────────────────────────────────

  @doc "Who calls this node? (incoming calls edges, recursive)"
  def callers(node_name, opts \\ []) do
    max_depth = min(Keyword.get(opts, :depth, 1), @max_depth)
    node_id = resolve_id(node_name)

    sql = """
    WITH RECURSIVE caller_chain(depth, node_id, path) AS (
      SELECT 0, ?, ?
      UNION ALL
      SELECT c.depth + 1, e.source_id, c.path || ' → ' || e.source_id
      FROM caller_chain c
      JOIN edges e ON e.target_id = c.node_id AND e.type = 'calls'
      WHERE c.depth < ?
    )
    SELECT c.depth, n.id, n.name, n.type, n.file_path, n.start_line, n.end_line,
           n.properties, c.path
    FROM caller_chain c
    JOIN nodes n ON n.id = c.node_id
    WHERE c.depth > 0
    ORDER BY c.depth, n.name
    """

    exec(sql, [node_id, node_id, max_depth])
  end

  @doc "Who imports this module?"
  def importers(node_name) do
    node_id = resolve_id(node_name)

    sql = """
    SELECT n.id, n.name, n.type, n.file_path, n.start_line
    FROM nodes n
    JOIN edges e ON e.source_id = n.id
    WHERE e.target_id = ? AND e.type = 'imports'
    ORDER BY n.file_path, n.start_line
    """

    exec(sql, [node_id])
  end

  # ── Outgoing relationships ───────────────────────────────────

  @doc "What does this node call? (outgoing calls edges, recursive)"
  def callees(node_name, opts \\ []) do
    max_depth = min(Keyword.get(opts, :depth, 1), @max_depth)
    node_id = resolve_id(node_name)

    sql = """
    WITH RECURSIVE callee_chain(depth, node_id, path) AS (
      SELECT 0, ?, ?
      UNION ALL
      SELECT c.depth + 1, e.target_id, c.path || ' → ' || e.target_id
      FROM callee_chain c
      JOIN edges e ON e.source_id = c.node_id AND e.type = 'calls'
      WHERE c.depth < ?
    )
    SELECT c.depth, n.id, n.name, n.type, n.file_path, n.start_line, n.end_line,
           n.properties, c.path
    FROM callee_chain c
    JOIN nodes n ON n.id = c.node_id
    WHERE c.depth > 0
    ORDER BY c.depth, n.name
    """

    exec(sql, [node_id, node_id, max_depth])
  end

  @doc "What does this module import?"
  def imports(node_name) do
    node_id = resolve_id(node_name)

    sql = """
    SELECT n.id, n.name, n.type, n.file_path
    FROM nodes n
    JOIN edges e ON e.target_id = n.id
    WHERE e.source_id = ? AND e.type = 'imports'
    ORDER BY n.name
    """

    exec(sql, [node_id])
  end

  # ── Inheritance ──────────────────────────────────────────────

  @doc "Inheritance chain upward (what does this extend?)"
  def ancestors(node_name) do
    node_id = resolve_id(node_name)

    sql = """
    WITH RECURSIVE ancestor_chain(depth, node_id, path) AS (
      SELECT 0, ?, ?
      UNION ALL
      SELECT ac.depth + 1, e.target_id, ac.path || ' → ' || e.target_id
      FROM ancestor_chain ac
      JOIN edges e ON e.source_id = ac.node_id AND e.type = 'extends'
      WHERE ac.depth < #{@max_depth}
    )
    SELECT ac.depth, n.id, n.name, n.type, n.file_path, n.properties, ac.path
    FROM ancestor_chain ac
    JOIN nodes n ON n.id = ac.node_id
    WHERE ac.depth > 0
    ORDER BY ac.depth
    """

    exec(sql, [node_id, node_id])
  end

  @doc "All subclasses transitively."
  def descendants(node_name) do
    node_id = resolve_id(node_name)

    sql = """
    WITH RECURSIVE descendant_chain(depth, node_id, path) AS (
      SELECT 0, ?, ?
      UNION ALL
      SELECT dc.depth + 1, e.source_id, dc.path || ' → ' || e.source_id
      FROM descendant_chain dc
      JOIN edges e ON e.target_id = dc.node_id AND e.type = 'extends'
      WHERE dc.depth < #{@max_depth}
    )
    SELECT dc.depth, n.id, n.name, n.type, n.file_path, n.properties, dc.path
    FROM descendant_chain dc
    JOIN nodes n ON n.id = dc.node_id
    WHERE dc.depth > 0
    ORDER BY dc.depth, n.name
    """

    exec(sql, [node_id, node_id])
  end

  @doc "Classes implementing an interface/protocol/trait."
  def implementations(interface_name) do
    node_id = resolve_id(interface_name)

    sql = """
    SELECT n.id, n.name, n.type, n.file_path, n.start_line, n.properties
    FROM nodes n
    JOIN edges e ON e.source_id = n.id
    WHERE e.target_id = ? AND e.type = 'implements'
    ORDER BY n.file_path, n.name
    """

    exec(sql, [node_id])
  end

  # ── Neighborhood ─────────────────────────────────────────────

  @doc """
  BFS subgraph around a node up to the given depth.
  Returns %{nodes: [...], edges: [...]} suitable for graph visualization.
  """
  def neighborhood(node_name, depth \\ 1) do
    node_id = resolve_id(node_name)
    max_depth = min(depth, @max_depth)

    # Collect all nodes within radius via BFS
    sql_nodes = """
    WITH RECURSIVE bfs(d, node_id) AS (
      SELECT 0, ?
      UNION
      SELECT bfs.d + 1, e.source_id FROM bfs
      JOIN edges e ON e.target_id = bfs.node_id WHERE bfs.d < ?
      UNION
      SELECT bfs.d + 1, e.target_id FROM bfs
      JOIN edges e ON e.source_id = bfs.node_id WHERE bfs.d < ?
    )
    SELECT DISTINCT n.id, n.name, n.type, n.file_path, n.start_line
    FROM bfs
    JOIN nodes n ON n.id = bfs.node_id
    """

    # Get edges between collected nodes
    sql_edges = """
    WITH RECURSIVE bfs(d, node_id) AS (
      SELECT 0, ?
      UNION
      SELECT bfs.d + 1, e2.source_id FROM bfs
      JOIN edges e2 ON e2.target_id = bfs.node_id WHERE bfs.d < ?
      UNION
      SELECT bfs.d + 1, e2.target_id FROM bfs
      JOIN edges e2 ON e2.source_id = bfs.node_id WHERE bfs.d < ?
    ),
    in_subgraph AS (
      SELECT DISTINCT node_id FROM bfs
    )
    SELECT e.source_id, e.target_id, e.type, e.confidence
    FROM edges e
    WHERE e.source_id IN (SELECT node_id FROM in_subgraph)
      AND e.target_id IN (SELECT node_id FROM in_subgraph)
    """

    with {:ok, nodes} <- exec(sql_nodes, [node_id, max_depth, max_depth]),
         {:ok, edges} <- exec(sql_edges, [node_id, max_depth, max_depth]) do
      {:ok, %{
        center: node_name,
        depth: max_depth,
        node_count: length(nodes),
        edge_count: length(edges),
        nodes: Enum.map(nodes, fn [id, name, type, file, line] ->
          %{id: id, name: name, type: type, file: file, line: line}
        end),
        edges: Enum.map(edges, fn [src, tgt, type, conf] ->
          %{source: src, target: tgt, type: type, confidence: conf}
        end)
      }}
    end
  end

  # ── Graph Analysis ───────────────────────────────────────────

  @doc "Highest-degree nodes (hubs in the call graph)."
  def god_nodes(top_n \\ 10) do
    sql = """
    SELECT n.id, n.name, n.type, n.file_path,
           (SELECT COUNT(*) FROM edges e WHERE e.source_id = n.id) +
           (SELECT COUNT(*) FROM edges e WHERE e.target_id = n.id) as degree
    FROM nodes n
    WHERE type IN ('function', 'method', 'module', 'class')
    ORDER BY degree DESC
    LIMIT ?
    """

    with {:ok, rows} <- exec(sql, [top_n]) do
      {:ok, Enum.map(rows, fn [id, name, type, file, degree] ->
        %{id: id, name: name, type: type, file: file, degree: degree}
      end)}
    end
  end

  @doc "Nodes that bridge between different modules/packages."
  def bridge_nodes(top_n \\ 10) do
    sql = """
    WITH node_module AS (
      SELECT n.id, n.name, n.type,
             COALESCE(n.file_path, '') as file_path,
             n.parent_id
      FROM nodes n
    ),
    edge_modules AS (
      SELECT e.source_id, e.target_id,
             COALESCE(n1.file_path, '') as source_file,
             COALESCE(n2.file_path, '') as target_file
      FROM edges e
      JOIN nodes n1 ON n1.id = e.source_id
      JOIN nodes n2 ON n2.id = e.target_id
      WHERE e.type = 'calls'
    ),
    cross_module AS (
      SELECT DISTINCT source_id as bridge_id,
             COUNT(DISTINCT target_file) as unique_targets
      FROM edge_modules
      WHERE source_file != target_file
        AND source_file != ''
        AND target_file != ''
      GROUP BY source_id
      HAVING unique_targets >= 2
    )
    SELECT n.id, n.name, n.type, n.file_path, cm.unique_targets as community_reach
    FROM cross_module cm
    JOIN nodes n ON n.id = cm.bridge_id
    ORDER BY cm.unique_targets DESC
    LIMIT ?
    """

    with {:ok, rows} <- exec(sql, [top_n]) do
      {:ok, Enum.map(rows, fn [id, name, type, file, reach] ->
        %{id: id, name: name, type: type, file: file, community_reach: reach}
      end)}
    end
  end

  @doc "Transitive dependents (everything that depends on this node, directly or transitively)."
  def dependents(node_name, depth \\ nil) do
    node_id = resolve_id(node_name)
    max_depth = if depth, do: min(depth, @max_depth), else: @max_depth

    sql = """
    WITH RECURSIVE dep_chain(depth, node_id) AS (
      SELECT 0, ?
      UNION ALL
      SELECT dc.depth + 1, e.source_id
      FROM dep_chain dc
      JOIN edges e ON e.target_id = dc.node_id
      WHERE dc.depth < ?
    )
    SELECT dc.depth, n.id, n.name, n.type, n.file_path
    FROM dep_chain dc
    JOIN nodes n ON n.id = dc.node_id
    WHERE dc.depth > 0
    ORDER BY dc.depth, n.name
    """

    exec(sql, [node_id, max_depth])
  end

  # ── Summary Stats ────────────────────────────────────────────

  @doc "Count nodes by type across all shards."
  def node_counts do
    sql = "SELECT type, COUNT(*) as cnt FROM nodes GROUP BY type ORDER BY cnt DESC"
    exec(sql, [])
  end

  @doc "Count edges by type across all shards."
  def edge_counts do
    sql = "SELECT type, COUNT(*) as cnt FROM edges GROUP BY type ORDER BY cnt DESC"
    exec(sql, [])
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp resolve_id(node_name) do
    # node_name could be an ID or a display name — try ID first, then name
    case exec("SELECT id FROM nodes WHERE id = ? LIMIT 1", [node_name]) do
      {:ok, [[id | _] | _]} -> id
      _ ->
        case exec("SELECT id FROM nodes WHERE name = ? LIMIT 1", [node_name]) do
          {:ok, [[id | _] | _]} -> id
          _ -> node_name  # fallback: use as-is
        end
    end
  end

  defp exec(sql, params) do
    # Query only shards that have nodes/edges tables.
    # Skip the routing DB and other non-graph shards.
    shards = Mosaic.ShardRouter.list_all_shards()
    |> Enum.filter(fn s ->
      case Mosaic.ConnectionPool.checkout(s.path) do
        {:ok, conn} ->
          result = Mosaic.DB.query_one(conn, "SELECT COUNT(*) FROM nodes")
          Mosaic.ConnectionPool.checkin(s.path, conn)
          match?({:ok, _}, result)
        _ -> false
      end
    end)

    if shards == [] do
      # Fallback: query routing DB
      with {:ok, conn} <- Mosaic.ConnectionPool.checkout(Mosaic.Config.get(:routing_db_path)) do
        result = Mosaic.DB.query(conn, sql, params)
        Mosaic.ConnectionPool.checkin(Mosaic.Config.get(:routing_db_path), conn)
        result
      else
        error -> error
      end
    else
      # Execute on each graph shard and merge
      results = Enum.flat_map(shards, fn shard ->
        case Mosaic.ConnectionPool.checkout(shard.path) do
          {:ok, conn} ->
            case Mosaic.DB.query(conn, sql, params) do
              {:ok, rows} -> rows
              _ -> []
            end
          _ -> []
        end
      end)
      {:ok, results}
    end
  end
end

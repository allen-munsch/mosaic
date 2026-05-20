defmodule Mosaic.Graph.Communities do
  @moduledoc """
  Community detection on the code graph using SQL-based Louvain-inspired
  optimization. Operates on the persistent nodes/edges tables.

  Ported from Matryoshka's graph-analyzer but adapted for SQL computation
  rather than in-memory graphology iteration.
  """

  @doc """
  Detect communities based on file-path proximity and call density.
  Returns communities with cohesion scores.

  Strategy: group by directory prefix (package/module boundary),
  then compute internal vs external edge ratios.
  """
  def detect(opts \\ []) do
    min_nodes = Keyword.get(opts, :min_nodes, 3)

    sql = """
    WITH node_degrees AS (
      SELECT n.id, n.file_path,
             (SELECT COUNT(*) FROM edges e WHERE e.source_id = n.id) as out_degree,
             (SELECT COUNT(*) FROM edges e WHERE e.target_id = n.id) as in_degree,
             SUBSTR(COALESCE(n.file_path, ''), 1,
                    INSTR(COALESCE(n.file_path, '/'), '/') - 1) as community
      FROM nodes n
    ),
    community_stats AS (
      SELECT community,
             COUNT(*) as node_count,
             SUM(out_degree + in_degree) as total_degree,
             SUM(out_degree) as total_out,
             SUM(in_degree) as total_in
      FROM node_degrees
      WHERE community != ''
      GROUP BY community
      HAVING node_count >= ?
    ),
    internal_edges AS (
      SELECT cs.community,
             COUNT(*) as internal_count
      FROM edges e
      JOIN nodes n1 ON n1.id = e.source_id
      JOIN nodes n2 ON n2.id = e.target_id
      JOIN community_stats cs ON cs.community = SUBSTR(COALESCE(n1.file_path, ''), 1,
                              INSTR(COALESCE(n1.file_path, '/'), '/') - 1)
      WHERE SUBSTR(COALESCE(n1.file_path, ''), 1,
                   INSTR(COALESCE(n1.file_path, '/'), '/') - 1) = cs.community
        AND SUBSTR(COALESCE(n2.file_path, ''), 1,
                   INSTR(COALESCE(n2.file_path, '/'), '/') - 1) = cs.community
      GROUP BY cs.community
    )
    SELECT cs.community, cs.node_count, cs.total_degree,
           COALESCE(ie.internal_count, 0) as internal_edges,
           ROUND(CAST(COALESCE(ie.internal_count, 0) AS REAL) /
                 MAX(cs.total_out, 1), 3) as cohesion
    FROM community_stats cs
    LEFT JOIN internal_edges ie ON ie.community = cs.community
    ORDER BY cs.node_count DESC
    """

    with {:ok, rows} <- exec(sql, [min_nodes]) do
      {:ok, Enum.map(rows, fn [community, node_count, total_deg, internal, cohesion] ->
        %{
          community: community,
          node_count: node_count,
          total_degree: total_deg,
          internal_edges: internal,
          cohesion: cohesion
        }
      end)}
    end
  end

  @doc "Which community does a given node belong to?"
  def community_of(node_name) do
    node_id = resolve_id(node_name)
    sql = """
    SELECT SUBSTR(COALESCE(file_path, ''), 1,
           INSTR(COALESCE(file_path, '/'), '/') - 1) as community
    FROM nodes WHERE id = ? OR name = ?
    LIMIT 1
    """

    with {:ok, [[community] | _]} <- exec(sql, [node_id, node_name]) do
      {:ok, community}
    end
  end

  # ── Private ──────────────────────────────────────────────────

  defp resolve_id(node_name) do
    case exec("SELECT id FROM nodes WHERE id = ? OR name = ? LIMIT 1", [node_name, node_name]) do
      {:ok, [[id | _] | _]} -> id
      _ -> node_name
    end
  end

  defp exec(sql, params) do
    result = Mosaic.FederatedQuery.execute(sql, params)
    case result do
      rows when is_list(rows) -> {:ok, rows}
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  rescue
    _ ->
      with {:ok, conn} <- Mosaic.ConnectionPool.checkout(Mosaic.Config.get(:routing_db_path)) do
        result = Mosaic.DB.query(conn, sql, params)
        Mosaic.ConnectionPool.checkin(Mosaic.Config.get(:routing_db_path), conn)
        result
      else
        error -> error
      end
  end
end

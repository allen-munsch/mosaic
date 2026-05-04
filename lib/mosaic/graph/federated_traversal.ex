defmodule Mosaic.Graph.FederatedTraversal do
  @moduledoc """
  Cross-shard graph traversals — fan out recursive CTEs to all shards,
  merge results, and resolve cross-shard edge references.

  When the graph spans multiple SQLite shards (partitioned by package/
  module boundary), edges may cross shard boundaries. This module handles:

    1. Fan-out: execute a traversal query on every shard in parallel
    2. Merge: deduplicate results across shards
    3. Resolve: follow cross-shard edges (external references)

  ## Cross-Shard Edge Model

  Edges whose target_id resolves to a node in another shard are marked
  with a synthetic `external:` prefix in the target_id. FederatedTraversal
  detects these and fans out the resolution across shards.
  """

  require Logger

  @doc """
  Execute a traversal across all shards, merging results.

  The traversal function receives a shard connection and returns
  {:ok, rows} for that shard. Results are merged and deduplicated
  by node ID.
  """
  def traverse_all(traversal_fn, opts \\ []) do
    shards = list_shards()
    timeout = Keyword.get(opts, :timeout, 15_000)
    dedup_key = Keyword.get(opts, :dedup_key, :id)

    shards
    |> Task.async_stream(
      fn shard -> execute_on_shard(shard, traversal_fn) end,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, {:ok, rows}}, acc -> acc ++ rows
      {:ok, {:error, reason}}, acc ->
        Logger.warning("Shard traversal failed: #{inspect(reason)}")
        acc
      {:exit, :timeout}, acc ->
        Logger.warning("Shard traversal timed out")
        acc
    end)
    |> deduplicate(dedup_key)
    |> then(&{:ok, &1})
  end

  @doc """
  Resolve cross-shard references. Given a list of node IDs that may
  contain external: prefix references, resolves them across all shards.
  """
  def resolve_external(external_ids, opts \\ []) do
    shards = list_shards()
    timeout = Keyword.get(opts, :timeout, 10_000)

    # Extract the actual name from external:file_path:name format
    names = external_ids
      |> Enum.filter(&String.starts_with?(&1, "external:"))
      |> Enum.map(fn id ->
        id
        |> String.replace_prefix("external:", "")
        |> String.split(":")
        |> List.last()
      end)

    if Enum.empty?(names) do
      {:ok, %{}}
    else
      shards
      |> Task.async_stream(
        fn shard -> resolve_names_on_shard(shard, names) end,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {:ok, resolved}}, acc -> Map.merge(acc, resolved)
        {:ok, {:error, _}}, acc -> acc
        {:exit, :timeout}, acc -> acc
      end)
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Follow edges across shard boundaries. Given a set of cross-shard edges
  (source in one shard, target potentially in another), resolves all
  targets and returns the connected subgraph.
  """
  def follow_cross_shard(source_ids, edge_type, opts \\ []) do
    max_depth = Keyword.get(opts, :depth, 1)
    shards = list_shards()
    timeout = Keyword.get(opts, :timeout, 15_000)

    # For each shard, find edges from source_ids and collect targets
    results = shards
      |> Task.async_stream(
        fn shard -> cross_shard_step(shard, source_ids, edge_type, max_depth) end,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{nodes: [], edges: [], visited: MapSet.new()}, fn
        {:ok, {:ok, partial}}, acc ->
          %{
            nodes: acc.nodes ++ partial.nodes,
            edges: acc.edges ++ partial.edges,
            visited: MapSet.union(acc.visited, partial.visited)
          }
        _, acc -> acc
      end)

    {:ok, results}
  end

  # ── Private ────────────────────────────────────────────────────

  defp execute_on_shard(shard, traversal_fn) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        try do
          traversal_fn.(conn)
        after
          Mosaic.ConnectionPool.checkin(shard.path, conn)
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_names_on_shard(shard, names) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        try do
          placeholders = Enum.map_join(names, ",", fn _ -> "?" end)
          sql = "SELECT id, name, type, file_path, start_line, properties FROM nodes WHERE name IN (#{placeholders})"

          case Mosaic.DB.query(conn, sql, names) do
            {:ok, rows} ->
              resolved = Map.new(rows, fn [id, name, type, file, line, props] ->
                {name, %{id: id, name: name, type: type, file: file, line: line, properties: props}}
              end)
              {:ok, resolved}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Mosaic.ConnectionPool.checkin(shard.path, conn)
        end

      {:error, _} = err ->
        err
    end
  end

  defp cross_shard_step(shard, source_ids, edge_type, depth) do
    case Mosaic.ConnectionPool.checkout(shard.path) do
      {:ok, conn} ->
        try do
          source_placeholders = Enum.map_join(source_ids, ",", fn _ -> "?" end)
          all_params = source_ids ++ source_ids ++ [edge_type, depth]

          sql = """
          WITH RECURSIVE step(d, node_id) AS (
            SELECT 0, e.target_id
            FROM edges e
            WHERE e.source_id IN (#{source_placeholders})
              AND e.type = ?
            UNION
            SELECT s.d + 1, e2.target_id
            FROM step s
            JOIN edges e2 ON e2.source_id = s.node_id AND e2.type = ?
            WHERE s.d < ?
              AND e2.target_id NOT IN (SELECT node_id FROM step)
          )
          SELECT DISTINCT s.d, n.id, n.name, n.type, n.file_path, n.start_line
          FROM step s
          JOIN nodes n ON n.id = s.node_id
          """

          case Mosaic.DB.query(conn, sql, all_params) do
            {:ok, rows} ->
              visited = MapSet.new(rows, fn [_, id | _] -> id end)
              targets = Enum.map(rows, fn [d, id, name, type, file, line] ->
                %{depth: d, id: id, name: name, type: type, file: file, line: line}
              end)

              {:ok, %{
                nodes: targets,
                edges: build_step_edges(source_ids, targets, edge_type),
                visited: visited
              }}

            {:error, reason} ->
              {:error, reason}
          end
        after
          Mosaic.ConnectionPool.checkin(shard.path, conn)
        end

      {:error, _} = err ->
        err
    end
  end

  defp build_step_edges(sources, targets, edge_type) do
    Enum.flat_map(sources, fn src ->
      Enum.map(targets, fn tgt ->
        %{source: src, target: tgt.id, type: edge_type}
      end)
    end)
  end

  defp deduplicate(rows, key) when is_atom(key) do
    Enum.uniq_by(rows, fn row ->
      case row do
        %{^key => val} -> val
        [val | _] when is_list(row) -> val
        val -> val
      end
    end)
  end

  defp list_shards do
    Mosaic.ShardRouter.list_all_shards()
  end
end

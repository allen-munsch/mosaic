defmodule Mosaic.Graph.Writer do
  @moduledoc """
  Transactional bulk writer for nodes and edges into SQLite shards.

  Handles embedding insertion at multiple matryoshka levels,
  edge deduplication, and parent-child relationship management.
  """

  require Logger

  @edge_types ~w(calls extends implements imports contains references)

  @doc """
  Write a complete subgraph (nodes + edges) in a single transaction.
  Returns {:ok, stats} with counts.
  """
  def write_subgraph(shard_path, nodes, edges, _opts \\ []) do
    with {:ok, conn} <- Mosaic.ConnectionPool.checkout(shard_path) do
      Mosaic.DB.execute(conn, "BEGIN IMMEDIATE")

      try do
        node_count = write_nodes(conn, nodes)

        # Build node ID set from what we just wrote for edge validation
        node_ids = MapSet.new(nodes, &(Map.get(&1, :id) || generate_id(&1)))
        edge_count = write_edges(conn, edges, node_ids)

        Mosaic.DB.execute(conn, "COMMIT")

        {:ok, %{
          shard: shard_path,
          nodes_written: node_count,
          edges_written: edge_count
        }}
      rescue
        e ->
          Mosaic.DB.execute(conn, "ROLLBACK")
          Logger.error("write_subgraph failed: #{inspect(e)}")
          {:error, e}
      after
        Mosaic.ConnectionPool.checkin(shard_path, conn)
      end
    end
  end

  @doc """
  Write nodes with optional matryoshka embedding levels.
  Each node gets inserted into its vec_nodes_* virtual table
  at each configured dimension.
  """
  def write_nodes(conn, nodes) when is_list(nodes) do
    insert_node = """
    INSERT OR REPLACE INTO nodes
      (id, name, type, language, file_path, start_line, end_line,
       source_text, parent_id, properties, embedding, embedding_256, embedding_128, embedding_64)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    matryoshka_levels = Mosaic.Config.get(:matryoshka_levels, [64, 128, 256, 384])

    Enum.reduce(nodes, 0, fn node, count ->
      embedding = Map.get(node, :embedding)
      embedding_binary = if embedding, do: encode_embedding(embedding), else: nil

      params = [
        Map.get(node, :id) || generate_id(node),
        Map.get(node, :name, ""),
        Map.get(node, :type, "unknown"),
        Map.get(node, :language),
        Map.get(node, :file_path),
        Map.get(node, :start_line),
        Map.get(node, :end_line),
        Map.get(node, :source_text),
        Map.get(node, :parent_id),
        encode_json(Map.get(node, :properties, %{})),
        embedding_binary,
        truncate_and_encode(embedding, 256),
        truncate_and_encode(embedding, 128),
        truncate_and_encode(embedding, 64)
      ]

      Mosaic.DB.execute(conn, insert_node, params)
      node_id = Map.get(node, :id) || generate_id(node)

      # Insert into vec tables at each matryoshka level
      if embedding do
        Enum.each(matryoshka_levels, fn dims ->
          truncated = Enum.take(embedding, dims)
          insert_vec(conn, dims, node_id, truncated)
        end)
      end

      count + 1
    end)
  end

  @doc """
  Write edges with deduplication (UNIQUE index on source+target+type).
  Skips edges referencing non-existent nodes.
  """
  def write_edges(conn, edges, node_ids \\ MapSet.new()) do
    node_set = if MapSet.size(node_ids) > 0 do
      node_ids
    else
      # Build set from existing nodes
      {:ok, existing} = Mosaic.DB.query(conn, "SELECT id FROM nodes")
      MapSet.new(existing, fn [id] -> id end)
    end

    insert_edge = """
    INSERT OR IGNORE INTO edges
      (id, source_id, target_id, type, confidence, properties, weight)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    Enum.reduce(edges, 0, fn edge, count ->
      src = Map.get(edge, :source_id) || Map.get(edge, :source)
      tgt = Map.get(edge, :target_id) || Map.get(edge, :target)
      type = Map.get(edge, :type, "calls")

      if MapSet.member?(node_set, src) and MapSet.member?(node_set, tgt) and type in @edge_types do
        params = [
          Map.get(edge, :id) || "#{src}->#{tgt}:#{type}",
          src,
          tgt,
          type,
          Map.get(edge, :confidence, "EXTRACTED"),
          encode_json(Map.get(edge, :properties, %{})),
          Map.get(edge, :weight, 1.0)
        ]
        Mosaic.DB.execute(conn, insert_edge, params)
        count + 1
      else
        count
      end
    end)
  end

  # ── Private Helpers ──────────────────────────────────────────

  defp generate_id(node) do
    file = Map.get(node, :file_path, "")
    name = Map.get(node, :name, "")
    line = Map.get(node, :start_line, 0)

    hash =
      :crypto.hash(:sha256, "#{file}:#{name}:#{line}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "#{file}:#{name}:#{line}:#{hash}"
  end

  defp encode_embedding(embedding) when is_list(embedding) do
    for f <- embedding, into: <<>>, do: <<f::float-32-native>>
  end

  defp truncate_and_encode(nil, _dims), do: nil
  defp truncate_and_encode(embedding, dims) when is_list(embedding) do
    embedding |> Enum.take(dims) |> encode_embedding()
  end

  defp insert_vec(conn, dims, node_id, embedding) do
    table_name = :"vec_nodes_#{dims}"
    # vec0 uses INSERT to populate the virtual table
    # Format: encode as JSON array, then insert
    vec_json = Jason.encode!(embedding)
    Mosaic.DB.execute(conn,
      "INSERT OR REPLACE INTO #{table_name} (id, embedding) VALUES (?, ?)",
      [node_id, vec_json])
  rescue
    e -> Logger.warning("Failed vec insert into vec_nodes_#{dims}: #{inspect(e)}")
  end

  defp encode_json(map) when is_map(map), do: Jason.encode!(map)
  defp encode_json(_), do: "{}"
end

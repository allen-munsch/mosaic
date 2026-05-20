defmodule Mosaic.Graph.WriterTest do
  use ExUnit.Case, async: false

  alias Mosaic.Graph.Writer

  setup do
    shard_path = temp_shard("writer_test")
    on_exit(fn -> File.rm_rf(Path.dirname(shard_path)) end)
    {:ok, shard_path: shard_path}
  end

  test "write_subgraph creates nodes and edges", %{shard_path: shard_path} do
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    nodes = [
      %{id: "node:1", name: "func_one", type: "function", language: "elixir",
        file_path: "lib/test.ex", start_line: 1, end_line: 5,
        source_text: "def func_one, do: :ok", parent_id: nil, properties: %{visibility: "public"}},
      %{id: "node:2", name: "func_two", type: "function", language: "elixir",
        file_path: "lib/test.ex", start_line: 7, end_line: 10,
        source_text: "def func_two, do: func_one()", parent_id: nil, properties: %{}}
    ]

    edges = [
      %{source_id: "node:2", target_id: "node:1", type: "calls", confidence: "EXTRACTED", properties: %{line: 8}}
    ]

    {:ok, stats} = Writer.write_subgraph(shard_path, nodes, edges)

    assert stats.nodes_written == 2
    assert stats.edges_written == 1
    assert stats.shard == shard_path
  end

  test "write_nodes inserts with matryoshka levels", %{shard_path: shard_path} do
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)

    nodes = [
      %{id: "node:3", name: "test_func", type: "function", language: "elixir",
        file_path: "lib/test.ex", start_line: 1, end_line: 3,
        source_text: "def test_func, do: :ok", parent_id: nil,
        properties: %{},
        embedding: List.duplicate(0.1, 384)}
    ]

    count = Writer.write_nodes(conn, nodes)
    Mosaic.ConnectionPool.checkin(shard_path, conn)

    assert count == 1

    # Verify node exists
    {:ok, conn2} = Mosaic.ConnectionPool.checkout(shard_path)
    {:ok, [[name]]} = Mosaic.DB.query(conn2, "SELECT name FROM nodes WHERE id = ?", ["node:3"])
    Mosaic.ConnectionPool.checkin(shard_path, conn2)
    assert name == "test_func"
  end

  test "write_edges deduplicates by source+target+type", %{shard_path: shard_path} do
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)

    # Write nodes first
    nodes = [
      %{id: "n:1", name: "a", type: "function", language: "elixir",
        file_path: "lib/a.ex", start_line: 1, end_line: 2, source_text: "",
        parent_id: nil, properties: %{}},
      %{id: "n:2", name: "b", type: "function", language: "elixir",
        file_path: "lib/a.ex", start_line: 3, end_line: 4, source_text: "",
        parent_id: nil, properties: %{}}
    ]
    Writer.write_nodes(conn, nodes)

    # Write same edge twice
    node_set = MapSet.new(["n:1", "n:2"])
    edges = [
      %{source_id: "n:1", target_id: "n:2", type: "calls", confidence: "EXTRACTED", properties: %{}},
      %{source_id: "n:1", target_id: "n:2", type: "calls", confidence: "EXTRACTED", properties: %{}}
    ]

    _count = Writer.write_edges(conn, edges, node_set)

    # Verify actual DB state — INSERT OR IGNORE deduplicates silently
    {:ok, [[db_count]]} = Mosaic.DB.query(conn, "SELECT COUNT(*) FROM edges")
    Mosaic.ConnectionPool.checkin(shard_path, conn)
    assert db_count == 1
  end

  test "write_edges skips missing nodes", %{shard_path: shard_path} do
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)

    # Only one node exists
    nodes = [
      %{id: "n:3", name: "c", type: "function", language: "elixir",
        file_path: "lib/c.ex", start_line: 1, end_line: 2, source_text: "",
        parent_id: nil, properties: %{}}
    ]
    Writer.write_nodes(conn, nodes)

    # Edge to nonexistent node
    edges = [
      %{source_id: "n:3", target_id: "n:nonexistent", type: "calls", confidence: "EXTRACTED", properties: %{}}
    ]

    node_set = MapSet.new(["n:3"])
    count = Writer.write_edges(conn, edges, node_set)
    Mosaic.ConnectionPool.checkin(shard_path, conn)

    assert count == 0  # skipped
  end

  test "write_subgraph with empty nodes", %{shard_path: shard_path} do
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    {:ok, stats} = Writer.write_subgraph(shard_path, [], [])
    assert stats.nodes_written == 0
    assert stats.edges_written == 0
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp temp_shard(suffix) do
    dir = Path.join(System.tmp_dir!(), "mosaic_test_#{suffix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, "test.db")
  end
end

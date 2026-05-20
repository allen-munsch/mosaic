defmodule Mosaic.Graph.TraversalTest do
  use ExUnit.Case, async: false

  alias Mosaic.Graph.{Writer, Traversal}

  setup do
    shard_path = temp_shard("traversal_test")
    create_test_graph(shard_path)
    # Register the shard so FederatedQuery can find it
    Mosaic.ShardRouter.register_shard(%{
      id: "traversal_test_shard",
      path: shard_path,
      centroids: %{document: List.duplicate(0.0, 384)},
      doc_count: 7,
      bloom_filter: nil
    })
    on_exit(fn -> File.rm_rf(Path.dirname(shard_path)) end)
    {:ok, shard_path: shard_path}
  end

  test "callers returns reverse call edges", %{shard_path: _path} do
    {:ok, results} = Traversal.callers("func_b", depth: 1)
    caller_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "func_a" in caller_names
  end

  test "callees returns forward call edges", %{shard_path: _path} do
    {:ok, results} = Traversal.callees("func_a", depth: 1)
    callee_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "func_b" in callee_names
  end

  test "callees with depth 2", %{shard_path: _path} do
    {:ok, results} = Traversal.callees("func_a", depth: 2)
    callee_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "func_b" in callee_names
    assert "func_c" in callee_names
  end

  test "ancestors follows extends chain", %{shard_path: _path} do
    {:ok, results} = Traversal.ancestors("ClassB")
    ancestor_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "ClassA" in ancestor_names
  end

  test "descendants returns transitive subclasses", %{shard_path: _path} do
    {:ok, results} = Traversal.descendants("ClassA")
    descendant_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "ClassB" in descendant_names
    assert "ClassC" in descendant_names
  end

  @tag :skip
  test "implementations returns classes implementing interface", %{shard_path: _path} do
    {:ok, results} = Traversal.implementations("MyProtocol")
    impl_names = Enum.map(results, fn [_, _, name | _] -> name end)
    assert "ClassA" in impl_names
  end

  test "neighborhood returns subgraph", %{shard_path: _path} do
    {:ok, hood} = Traversal.neighborhood("func_a", 1)
    assert is_map(hood)
    assert hood.center == "func_a"
    assert hood.node_count > 0
    assert hood.edge_count > 0
    assert is_list(hood.nodes)
  end

  test "god_nodes returns highest-degree nodes", %{shard_path: _path} do
    {:ok, nodes} = Traversal.god_nodes(5)
    assert is_list(nodes)
    assert length(nodes) <= 5
    if length(nodes) > 0, do: assert is_integer(hd(nodes).degree)
  end

  test "bridge_nodes returns cross-module connectors", %{shard_path: _path} do
    {:ok, nodes} = Traversal.bridge_nodes(5)
    assert is_list(nodes)
  end

  test "node_counts returns type counts", %{shard_path: _path} do
    {:ok, counts} = Traversal.node_counts()
    assert is_list(counts)
    types = Enum.map(counts, fn [type | _] -> type end)
    assert "function" in types
  end

  test "edge_counts returns type counts", %{shard_path: _path} do
    {:ok, counts} = Traversal.edge_counts()
    assert is_list(counts)
    types = Enum.map(counts, fn [type | _] -> type end)
    assert "calls" in types
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp temp_shard(suffix) do
    dir = Path.join(System.tmp_dir!(), "mosaic_test_#{suffix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Path.join(dir, "test.db")
  end

  defp create_test_graph(shard_path) do
    # Create shard
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)

    # Sample nodes
    nodes = [
      %{id: "mod:a:1", name: "func_a", type: "function", language: "elixir",
        file_path: "lib/mosaic/api.ex", start_line: 10, end_line: 20,
        source_text: "def func_a, do: func_b()", parent_id: nil, properties: %{}},
      %{id: "mod:a:2", name: "func_b", type: "function", language: "elixir",
        file_path: "lib/mosaic/api.ex", start_line: 22, end_line: 30,
        source_text: "def func_b, do: func_c()", parent_id: nil, properties: %{}},
      %{id: "mod:b:1", name: "func_c", type: "function", language: "elixir",
        file_path: "lib/mosaic/query.ex", start_line: 5, end_line: 15,
        source_text: "def func_c, do: :ok", parent_id: nil, properties: %{}},
      %{id: "mod:c:1", name: "ClassA", type: "class", language: "elixir",
        file_path: "lib/mosaic/base.ex", start_line: 1, end_line: 30,
        source_text: "defmodule ClassA do ... end", parent_id: nil, properties: %{}},
      %{id: "mod:c:2", name: "ClassB", type: "class", language: "elixir",
        file_path: "lib/mosaic/child.ex", start_line: 1, end_line: 25,
        source_text: "defmodule ClassB do ... end", parent_id: "mod:c:1", properties: %{}},
      %{id: "mod:c:3", name: "ClassC", type: "class", language: "elixir",
        file_path: "lib/mosaic/grandchild.ex", start_line: 1, end_line: 20,
        source_text: "defmodule ClassC do ... end", parent_id: "mod:c:2", properties: %{}},
      %{id: "mod:d:1", name: "MyProtocol", type: "interface", language: "elixir",
        file_path: "lib/mosaic/protocol.ex", start_line: 1, end_line: 15,
        source_text: "defprotocol MyProtocol do ... end", parent_id: nil, properties: %{}},
    ]

    edges = [
      %{source_id: "mod:a:1", target_id: "mod:a:2", type: "calls", confidence: "EXTRACTED", properties: %{}},
      %{source_id: "mod:a:2", target_id: "mod:b:1", type: "calls", confidence: "EXTRACTED", properties: %{}},
      %{source_id: "mod:c:2", target_id: "mod:c:1", type: "extends", confidence: "EXTRACTED", properties: %{}},
      %{source_id: "mod:c:3", target_id: "mod:c:2", type: "extends", confidence: "EXTRACTED", properties: %{}},
      %{source_id: "mod:c:1", target_id: "mod:d:1", type: "implements", confidence: "EXTRACTED", properties: %{}},
    ]

    Writer.write_subgraph(shard_path, nodes, edges)
  end
end

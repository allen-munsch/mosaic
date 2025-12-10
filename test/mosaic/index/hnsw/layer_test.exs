defmodule Mosaic.Index.HNSW.LayerTest do
  use ExUnit.Case, async: true
  alias Mosaic.Index.HNSW.{Layer, Node}

  setup do
    {:ok, layer: Layer.new()}
  end

  test "new creates empty layer", %{layer: layer} do
    assert layer.nodes == %{}
    assert layer.connections == %{}
  end

  test "add_node inserts node", %{layer: layer} do
    node = %Node{id: "n1", vector: [0.1], level: 0, neighbors: %{}, metadata: %{}}
    updated = Layer.add_node(layer, node)
    assert Map.has_key?(updated.nodes, "n1")
    assert Map.has_key?(updated.connections, "n1")
  end

  test "remove_node deletes node and connections", %{layer: layer} do
    n1 = %Node{id: "n1", vector: [0.1], level: 0, neighbors: %{}, metadata: %{}}
    n2 = %Node{id: "n2", vector: [0.2], level: 0, neighbors: %{}, metadata: %{}}
    layer = layer |> Layer.add_node(n1) |> Layer.add_node(n2) |> Layer.connect("n1", ["n2"])
    updated = Layer.remove_node(layer, "n1")
    refute Map.has_key?(updated.nodes, "n1")
    refute MapSet.member?(Map.get(updated.connections, "n2", MapSet.new()), "n1")
  end

  test "get_node returns node or nil", %{layer: layer} do
    node = %Node{id: "n1", vector: [0.1], level: 0, neighbors: %{}, metadata: %{}}
    layer = Layer.add_node(layer, node)
    assert Layer.get_node(layer, "n1") == node
    assert Layer.get_node(layer, "nonexistent") == nil
  end

  test "connect creates bidirectional edges", %{layer: layer} do
    n1 = %Node{id: "n1", vector: [0.1], level: 0, neighbors: %{}, metadata: %{}}
    n2 = %Node{id: "n2", vector: [0.2], level: 0, neighbors: %{}, metadata: %{}}
    layer = layer |> Layer.add_node(n1) |> Layer.add_node(n2) |> Layer.connect("n1", ["n2"])
    assert "n2" in Layer.get_neighbors(layer, "n1")
    assert "n1" in Layer.get_neighbors(layer, "n2")
  end

  test "get_any_node returns node from non-empty layer" do
    layer = Layer.new()
    node = %Node{id: "n1", vector: [0.1], level: 0, neighbors: %{}, metadata: %{}}
    layer = Layer.add_node(layer, node)
    assert Layer.get_any_node(layer) != nil
  end

  test "get_any_node returns nil for empty layer" do
    assert Layer.get_any_node(Layer.new()) == nil
  end

  test "shrink_connections limits neighbor count", %{layer: layer} do
    nodes = for i <- 1..5, do: %Node{id: "n#{i}", vector: [0.1 * i], level: 0, neighbors: %{}, metadata: %{}}
    layer = Enum.reduce(nodes, layer, &Layer.add_node(&2, &1))
    layer = Enum.reduce(2..5, layer, fn i, l -> Layer.connect(l, "n1", ["n#{i}"]) end)
    shrunk = Layer.shrink_connections(layer, "n1", 2)
    assert length(Layer.get_neighbors(shrunk, "n1")) <= 2
  end
end

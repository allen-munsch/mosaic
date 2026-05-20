defmodule Mosaic.Index.HNSW.NodeTest do
  use ExUnit.Case, async: true
  alias Mosaic.Index.HNSW.Node

  test "creates node with required fields" do
    node = %Node{id: "n1", vector: [0.1, 0.2], level: 2, neighbors: %{}, metadata: %{}}
    assert node.id == "n1"
    assert node.level == 2
    assert node.neighbors == %{}
  end

  test "node struct has correct keys" do
    keys = Map.keys(%Node{})
    assert :id in keys
    assert :vector in keys
    assert :level in keys
    assert :neighbors in keys
    assert :metadata in keys
  end
end

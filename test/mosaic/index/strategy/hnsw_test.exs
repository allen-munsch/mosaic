defmodule Mosaic.Index.Strategy.HNSWTest do
  use ExUnit.Case, async: true
  import Mosaic.StrategyTestHelpers
  alias Mosaic.Index.Strategy.HNSW

  setup do
    base_path = temp_path("hnsw_test")
    {:ok, state} = HNSW.init(base_path: base_path, m: 4, ef_construction: 20, ef_search: 10, dim: 8)
    on_exit(fn -> File.rm_rf!(base_path) end)
    {:ok, state: state, base_path: base_path}
  end

  test "implements strategy behaviour" do
    assert_strategy_behaviour(HNSW)
  end

  test "init creates valid state", %{state: state} do
    assert state.m == 4
    assert state.ef_construction == 20
    assert state.ef_search == 10
    assert state.node_count == 0
    assert state.entry_point == nil
  end

  test "index_document adds first node as entry point", %{state: state} do
    doc = %{id: "doc1", text: "test", metadata: %{}}
    embedding = random_embedding(8)
    {:ok, new_state} = HNSW.index_document(doc, embedding, state)
    assert new_state.node_count == 1
    assert new_state.entry_point != nil
    assert new_state.entry_point.id == "doc1"
  end

  test "index_document adds multiple nodes", %{state: state} do
    docs = sample_docs(5)
    final_state = Enum.reduce(docs, state, fn doc, s ->
      {:ok, new_s} = HNSW.index_document(doc, random_embedding(8), s)
      new_s
    end)
    assert final_state.node_count == 5
  end

  test "find_candidates returns empty for empty index", %{state: state} do
    {:ok, results} = HNSW.find_candidates(random_embedding(8), [limit: 5], state)
    assert results == []
  end

  test "find_candidates returns similar documents", %{base_path: base_path} do
    {:ok, state} = HNSW.init(base_path: base_path, m: 4, ef_construction: 50, ef_search: 20, dim: 8)
    
    # Target vector - all 0.5
    target_vec = List.duplicate(0.5, 8)
    {:ok, state} = HNSW.index_document(%{id: "target", text: "target", metadata: %{}}, target_vec, state)
    
    # Noise vectors - far from target
    noise_vecs = [
      [1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0],
      [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0],
      [1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0, 0.0],
      [0.0, 1.0, 0.0, -1.0, 0.0, 1.0, 0.0, -1.0]
    ]
    
    state = Enum.reduce(Enum.with_index(noise_vecs, 1), state, fn {vec, i}, acc ->
      {:ok, new_state} = HNSW.index_document(%{id: "noise_#{i}", text: "noise", metadata: %{}}, vec, acc)
      new_state
    end)
    
    # Query very close to target
    query = List.duplicate(0.51, 8)
    {:ok, results} = HNSW.find_candidates(query, [limit: 3], state)
    
    assert length(results) >= 1
    assert hd(results).id == "target"
  end

  test "delete_document removes node", %{state: state} do
    doc = %{id: "to_delete", text: "test", metadata: %{}}
    {:ok, state} = HNSW.index_document(doc, random_embedding(8), state)
    assert state.node_count == 1
    {:ok, state} = HNSW.delete_document("to_delete", state)
    assert state.node_count == 0
  end

  test "get_stats returns correct info", %{state: state} do
    {:ok, state} = HNSW.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(8), state)
    stats = HNSW.get_stats(state)
    assert stats.strategy == :hnsw
    assert stats.node_count == 1
    assert stats.m == 4
  end

  test "serialize and deserialize roundtrip", %{state: state} do
    {:ok, state} = HNSW.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(8), state)
    {:ok, binary} = HNSW.serialize(state)
    {:ok, restored} = HNSW.deserialize(binary, [])
    assert restored.node_count == state.node_count
    assert restored.m == state.m
  end
end

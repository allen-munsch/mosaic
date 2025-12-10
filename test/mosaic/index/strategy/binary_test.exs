defmodule Mosaic.Index.Strategy.BinaryTest do
  use ExUnit.Case, async: true
  import Mosaic.StrategyTestHelpers
  alias Mosaic.Index.Strategy.Binary

  setup do
    base_path = temp_path("binary_test")
    {:ok, state} = Binary.init(base_path: base_path, bits: 64)
    on_exit(fn -> File.rm_rf!(base_path) end)
    {:ok, state: state}
  end

  test "implements strategy behaviour" do
    assert_strategy_behaviour(Binary)
  end

  test "init creates valid state", %{state: state} do
    assert state.bits == 64
    assert state.doc_count == 0
    assert state.storage == %{}
  end

  test "index_document stores binary code", %{state: state} do
    doc = %{id: "doc1", text: "test", metadata: %{"k" => "v"}}
    embedding = random_embedding(64)
    {:ok, new_state} = Binary.index_document(doc, embedding, state)
    assert new_state.doc_count == 1
    assert Map.has_key?(new_state.storage, "doc1")
  end

  test "index_batch indexes multiple documents", %{state: state} do
    docs = for i <- 1..3, do: {%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(64)}
    {:ok, new_state} = Binary.index_batch(docs, state)
    assert new_state.doc_count == 3
  end

  test "delete_document removes entry", %{state: state} do
    doc = %{id: "del", text: "t", metadata: %{}}
    {:ok, state} = Binary.index_document(doc, random_embedding(64), state)
    {:ok, state} = Binary.delete_document("del", state)
    assert state.doc_count == 0
    refute Map.has_key?(state.storage, "del")
  end

  test "find_candidates returns results by hamming distance", %{state: state} do
    base = List.duplicate(0.9, 64)
    {:ok, state} = Binary.index_document(%{id: "target", text: "t", metadata: %{}}, base, state)
    state = Enum.reduce(1..3, state, fn i, acc ->
      {:ok, new_state} = Binary.index_document(%{id: "n#{i}", text: "t", metadata: %{}}, random_embedding(64), acc)
      new_state
    end)
    {:ok, results} = Binary.find_candidates(similar_embedding(base, 0.01), [limit: 2], state)
    assert length(results) >= 1
    assert hd(results).id == "target"
  end

  test "get_stats returns strategy info", %{state: state} do
    stats = Binary.get_stats(state)
    assert stats.strategy == :binary
    assert stats.bits == 64
  end
end

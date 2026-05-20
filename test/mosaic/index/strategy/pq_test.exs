defmodule Mosaic.Index.Strategy.PQTest do
  use ExUnit.Case, async: true
  import Mosaic.StrategyTestHelpers
  alias Mosaic.Index.Strategy.PQ

  setup do
    base_path = temp_path("pq_test")
    {:ok, state} = PQ.init(base_path: base_path, m: 2, k_sub: 4, training_size: 8, dim: 8)
    on_exit(fn -> File.rm_rf!(base_path) end)
    {:ok, state: state}
  end

  test "implements strategy behaviour" do
    assert_strategy_behaviour(PQ)
  end

  test "init validates dimension divisibility" do
    assert {:error, _} = PQ.init(dim: 10, m: 3)
  end

  test "init creates valid state", %{state: state} do
    assert state.m == 2
    assert state.k_sub == 4
    assert state.sub_dim == 4
    assert state.trained == false
  end

  test "buffers before training", %{state: state} do
    {:ok, state} = PQ.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(8), state)
    assert length(state.training_buffer) == 1
    assert state.trained == false
  end

  test "trains codebooks after threshold", %{state: state} do
    final = Enum.reduce(1..8, state, fn i, s ->
      {:ok, new_s} = PQ.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(8), s)
      new_s
    end)
    assert final.trained == true
    assert length(final.codebooks) == 2
  end

  test "find_candidates uses asymmetric distance", %{state: state} do
    base = random_embedding(8)
    state = Enum.reduce(1..8, state, fn i, s ->
      emb = if i == 1, do: base, else: random_embedding(8)
      {:ok, new_s} = PQ.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, emb, s)
      new_s
    end)
    {:ok, results} = PQ.find_candidates(similar_embedding(base, 0.01), [limit: 3], state)
    assert length(results) > 0
  end

  test "get_stats shows compression ratio", %{state: state} do
    state = Enum.reduce(1..8, state, fn i, s ->
      {:ok, new_s} = PQ.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(8), s)
      new_s
    end)
    stats = PQ.get_stats(state)
    assert stats.strategy == :pq
    assert stats.compression_ratio > 1
  end

  test "delete_document removes code", %{state: state} do
    state = Enum.reduce(1..8, state, fn i, s ->
      {:ok, new_s} = PQ.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(8), s)
      new_s
    end)
    {:ok, state} = PQ.delete_document("d1", state)
    assert state.doc_count == 7
    refute Map.has_key?(state.codes, "d1")
  end
end

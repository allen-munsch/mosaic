defmodule Mosaic.Index.Strategy.IVFTest do
  use ExUnit.Case, async: true
  import Mosaic.StrategyTestHelpers
  alias Mosaic.Index.Strategy.IVF

  setup do
    base_path = temp_path("ivf_test")
    {:ok, state} = IVF.init(base_path: base_path, n_lists: 4, n_probe: 2, training_size: 10)
    on_exit(fn -> File.rm_rf!(base_path) end)
    {:ok, state: state}
  end

  test "implements strategy behaviour" do
    assert_strategy_behaviour(IVF)
  end

  test "init creates valid state", %{state: state} do
    assert state.n_lists == 4
    assert state.n_probe == 2
    assert state.training_size == 10
    assert state.trained == false
  end

  test "buffers documents before training", %{state: state} do
    doc = %{id: "d1", text: "t", metadata: %{}}
    {:ok, new_state} = IVF.index_document(doc, random_embedding(8), state)
    assert length(new_state.training_buffer) == 1
    assert new_state.trained == false
  end

  test "trains after reaching training_size", %{state: state} do
    final_state = Enum.reduce(1..10, state, fn i, s ->
      {:ok, new_s} = IVF.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(8), s)
      new_s
    end)
    assert final_state.trained == true
    assert length(final_state.centroids) > 0
  end

  test "find_candidates works on buffer before training", %{state: state} do
    {:ok, state} = IVF.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(8), state)
    {:ok, results} = IVF.find_candidates(random_embedding(8), [limit: 5], state)
    assert is_list(results)
  end

  test "find_candidates searches clusters after training", %{state: state} do
    base = random_embedding(8)
    state = Enum.reduce(1..10, state, fn i, s ->
      emb = if i == 1, do: base, else: random_embedding(8)
      {:ok, new_s} = IVF.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, emb, s)
      new_s
    end)
    {:ok, results} = IVF.find_candidates(similar_embedding(base, 0.01), [limit: 3], state)
    assert length(results) > 0
  end

  test "delete_document removes from inverted lists", %{state: state} do
    state = Enum.reduce(1..10, state, fn i, s ->
      {:ok, new_s} = IVF.index_document(%{id: "d#{i}", text: "t", metadata: %{}}, random_embedding(8), s)
      new_s
    end)
    {:ok, state} = IVF.delete_document("d1", state)
    assert state.doc_count == 9
  end

  test "get_stats returns cluster info", %{state: state} do
    stats = IVF.get_stats(state)
    assert stats.strategy == :ivf
    assert stats.n_lists == 4
    assert stats.trained == false
  end
end

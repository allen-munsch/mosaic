defmodule Mosaic.Index.StrategyIntegrationTest do
  use ExUnit.Case, async: false
  import Mosaic.StrategyTestHelpers

  @strategies [:hnsw, :binary, :ivf, :pq]

  describe "all strategies implement consistent interface" do
    for strategy <- @strategies do
      @tag strategy: strategy
      test "#{strategy} indexes and retrieves documents" do
        strategy = unquote(strategy)
        base_path = temp_path("integration_#{strategy}")
        opts = strategy_opts(strategy, base_path)
        module = Mosaic.Index.StrategyFactory.get_module(strategy)
        {:ok, state} = module.init(opts)

        base_emb = base_embedding_for_strategy(strategy, opts[:dim] || 64)
        doc = %{id: "target", text: "target document", metadata: %{"tag" => "test"}}
        {:ok, state} = module.index_document(doc, base_emb, state)

        state = Enum.reduce(1..5, state, fn i, acc_state ->
          noise_emb = orthogonal_noise_embedding(i, opts[:dim] || 64)
          {:ok, new_state} = module.index_document(%{id: "noise_#{i}", text: "noise", metadata: %{}}, noise_emb, acc_state)
          new_state
        end)

        {:ok, results} = module.find_candidates(similar_embedding(base_emb, 0.05), [limit: 3], state)
        assert length(results) > 0
        assert Enum.any?(results, &(&1.id == "target"))

        File.rm_rf!(base_path)
      end
    end
  end

  describe "strategy switching" do
    test "can switch between strategies at runtime" do
      for strategy <- @strategies do
        {:ok, module, state} = Mosaic.Index.StrategyFactory.create(strategy, dim: 32, training_size: 5, n_lists: 2, m: 2, k_sub: 4, bits: 32)
        stats = module.get_stats(state)
        assert stats.strategy == strategy
      end
    end
  end

  defp strategy_opts(:hnsw, path), do: [base_path: path, m: 4, ef_construction: 10, ef_search: 5, dim: 64]
  defp strategy_opts(:binary, path), do: [base_path: path, bits: 64, dim: 64]
  defp strategy_opts(:ivf, path), do: [base_path: path, n_lists: 4, n_probe: 2, training_size: 6, dim: 64]
  defp strategy_opts(:pq, path), do: [base_path: path, m: 8, k_sub: 4, training_size: 6, dim: 64]

  defp base_embedding_for_strategy(:hnsw, dim), do: List.duplicate(0.5, dim)
  defp base_embedding_for_strategy(_, dim), do: random_embedding(dim)

  defp orthogonal_noise_embedding(seed, dim) do
    :rand.seed(:exsss, {seed * 1000, seed * 2000, seed * 3000})
    for i <- 1..dim do
      sign = if rem(i + seed, 2) == 0, do: 1, else: -1
      sign * :rand.uniform()
    end
  end
end

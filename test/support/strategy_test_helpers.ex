defmodule Mosaic.StrategyTestHelpers do
  import ExUnit.Assertions
  def temp_path(prefix) do
    Path.join(System.tmp_dir!(), "mosaic_test_#{prefix}_#{System.unique_integer([:positive])}")
  end

  def random_embedding(dim) do
    for _ <- 1..dim, do: :rand.uniform() * 2 - 1
  end

  def similar_embedding(base, noise_factor) do
    Enum.map(base, fn v -> v + (:rand.uniform() - 0.5) * noise_factor end)
  end

  def sample_docs(count) do
    for i <- 1..count, do: %{id: "doc_#{i}", text: "text #{i}", metadata: %{}}
  end

  def assert_strategy_behaviour(module) do
    behaviours = module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    assert Mosaic.Index.Strategy in behaviours
  end
end
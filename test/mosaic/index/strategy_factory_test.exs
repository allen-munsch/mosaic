defmodule Mosaic.Index.StrategyFactoryTest do
  use ExUnit.Case, async: true
  alias Mosaic.Index.StrategyFactory

  test "available_strategies returns all strategies" do
    strategies = StrategyFactory.available_strategies()
    assert :centroid in strategies
    assert :hnsw in strategies
    assert :binary in strategies
    assert :ivf in strategies
    assert :pq in strategies
  end

  test "get_module returns correct module for atom" do
    assert StrategyFactory.get_module(:hnsw) == Mosaic.Index.Strategy.HNSW
    assert StrategyFactory.get_module(:binary) == Mosaic.Index.Strategy.Binary
  end

  test "get_module returns correct module for string" do
    assert StrategyFactory.get_module("ivf") == Mosaic.Index.Strategy.IVF
  end

  test "get_module returns nil for unknown strategy" do
    assert StrategyFactory.get_module(:unknown) == nil
  end

  test "create initializes strategy" do
    {:ok, module, state} = StrategyFactory.create(:binary, bits: 128)
    assert module == Mosaic.Index.Strategy.Binary
    assert state.bits == 128
  end

  test "create returns error for unknown strategy" do
    assert {:error, {:unknown_strategy, :fake, _}} = StrategyFactory.create(:fake)
  end

  test "default_config returns config for each strategy" do
    assert is_list(StrategyFactory.default_config(:hnsw))
    assert Keyword.has_key?(StrategyFactory.default_config(:hnsw), :m)
    assert Keyword.has_key?(StrategyFactory.default_config(:binary), :bits)
    assert Keyword.has_key?(StrategyFactory.default_config(:ivf), :n_lists)
    assert Keyword.has_key?(StrategyFactory.default_config(:pq), :m)
  end

  test "recommend returns strategy for use case" do
    {strategy, opts} = StrategyFactory.recommend(:high_accuracy)
    assert strategy == :hnsw
    assert Keyword.has_key?(opts, :m)

    {strategy, _} = StrategyFactory.recommend(:fast_search)
    assert strategy == :binary

    {strategy, _} = StrategyFactory.recommend(:low_memory)
    assert strategy == :pq
  end
end

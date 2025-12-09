defmodule Mosaic.Index.StrategyFactory do
  @moduledoc """
  Factory for creating and configuring index strategies.

  Usage:
    {:ok, strategy, state} = StrategyFactory.create(:hnsw, [m: 32, ef_search: 100])
  """

  @strategies %{
    centroid: Mosaic.Index.Strategy.Centroid,
    quantized: Mosaic.Index.Strategy.Quantized,
    hnsw: Mosaic.Index.Strategy.HNSW,
    binary: Mosaic.Index.Strategy.Binary,
    ivf: Mosaic.Index.Strategy.IVF,
    pq: Mosaic.Index.Strategy.PQ
  }

  @doc "List all available strategies"
  def available_strategies, do: Map.keys( @strategies)

  @doc "Get strategy module by name"
  def get_module(strategy_name) when is_atom(strategy_name) do
    Map.get( @strategies, strategy_name)
  end

  def get_module(strategy_name) when is_binary(strategy_name) do
    get_module(String.to_atom(strategy_name))
  end

  @doc "Create and initialize a strategy"
  def create(strategy_name, opts \\ []) do
    case get_module(strategy_name) do
      nil ->
        {:error, {:unknown_strategy, strategy_name, available_strategies()}}
      module ->
        case module.init(opts) do
          {:ok, state} -> {:ok, module, state}
          error -> error
        end
    end
  end

  @doc "Get default configuration for a strategy"
  def default_config(:hnsw) do
    [m: 16, ef_construction: 200, ef_search: 50, distance_fn: :cosine]
  end

  def default_config(:binary) do
    [bits: 256, quantization: :mean, multi_probe: 1]
  end

  def default_config(:ivf) do
    [n_lists: 100, n_probe: 10, training_size: 1000]
  end

  def default_config(:pq) do
    [m: 8, k_sub: 256, training_size: 10000]
  end

  def default_config(:centroid), do: []
  def default_config(:quantized), do: []
  def default_config(_), do: []

  @doc "Recommended strategy based on use case"
  def recommend(use_case) do
    case use_case do
      :high_accuracy -> {:hnsw, [m: 32, ef_search: 100]}
      :fast_search -> {:binary, [bits: 512]}
      :low_memory -> {:pq, [m: 16, k_sub: 256]}
      :balanced -> {:ivf, [n_lists: 256, n_probe: 16]}
      :simple -> {:centroid, []}
      _ -> {:centroid, []}
    end
  end
end

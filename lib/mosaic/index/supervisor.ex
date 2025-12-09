defmodule Mosaic.Index.Supervisor do
  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    strategy_module = Keyword.fetch!(opts, :strategy)
    strategy_opts = Keyword.get(opts, :opts, [])
    
    Logger.info("Starting Index Supervisor with strategy: #{inspect(strategy_module)}")
    
    children = [
      # ShardRouter is needed for centroid strategy
      {Mosaic.ShardRouter, []},
      {Mosaic.BloomFilterManager, []},
      {Mosaic.RoutingMaintenance, []},
      {Mosaic.Indexer, []},
      # Strategy-specific GenServer (if needed)
      strategy_child_spec(strategy_module, strategy_opts)
    ]
    |> Enum.filter(& &1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp strategy_child_spec(Mosaic.Index.Strategy.Centroid, _opts), do: nil
  defp strategy_child_spec(Mosaic.Index.Strategy.Quantized, opts) do
    {Mosaic.Index.Quantized.CellRegistry, opts}
  end
  defp strategy_child_spec(strategy_module, opts) do
    # Generic strategy server wrapper
    {Mosaic.Index.StrategyServer, [strategy: strategy_module, opts: opts]}
  end
end

defmodule Mosaic.Index.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    strategy_module = Keyword.fetch!(opts, :strategy)
    
    children = [
      {strategy_module, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

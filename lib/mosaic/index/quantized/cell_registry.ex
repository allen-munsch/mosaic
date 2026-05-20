defmodule Mosaic.Index.Quantized.CellRegistry do
  use GenServer
  require Logger

  def start_link(quantized_strategy_config) do
    GenServer.start_link(__MODULE__, quantized_strategy_config, name: __MODULE__)
  end

  def init(quantized_strategy_config) do
    {:ok, %{cells: %{}, config: quantized_strategy_config}}
  end

  def get_or_create(quantized_path, %{base_path: base_path} = config) do
    cell_db_path = Path.join(base_path, "quantized/#{quantized_path}/cell.db")
    
    # Check if the GenServer is already running for this path
    case GenServer.whereis({:global, {:mosaic_quantized_cell, cell_db_path}}) do
      nil ->
        # If not running, start it
        Logger.info("Starting new quantized cell for path: #{cell_db_path}")
        {:ok, pid} = Mosaic.Index.Quantized.Cell.start_link(cell_db_path, config)
        pid
      pid ->
        # If already running, return its PID
        pid
    end
  end

  # GenServer callbacks - mainly for supervising child cells if we move to a dynamic supervisor
  # For now, it just holds the config and acts as a facade.
end

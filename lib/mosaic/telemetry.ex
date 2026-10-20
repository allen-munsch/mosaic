defmodule Mosaic.Telemetry do
  use GenServer

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec init(term()) :: {:ok, map()}
  def init(nil) do
    {:ok, %{}}
  end
end

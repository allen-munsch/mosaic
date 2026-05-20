defmodule Mosaic.Index.StrategyServer do
  @moduledoc """
  GenServer wrapper for index strategies that need stateful management.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    strategy_module = Keyword.fetch!(opts, :strategy)
    strategy_opts = Keyword.get(opts, :opts, [])
    
    Logger.info("Initializing strategy server for #{inspect(strategy_module)}")
    
    case strategy_module.init(strategy_opts) do
      {:ok, state} ->
        {:ok, %{module: strategy_module, state: state}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def index_document(doc, embedding) do
    GenServer.call(__MODULE__, {:index_document, doc, embedding}, 30_000)
  end

  def delete_document(doc_id) do
    GenServer.call(__MODULE__, {:delete_document, doc_id})
  end

  def find_candidates(query_embedding, opts \\ []) do
    GenServer.call(__MODULE__, {:find_candidates, query_embedding, opts}, 30_000)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  def optimize do
    GenServer.call(__MODULE__, :optimize, 60_000)
  end

  # Callbacks

  def handle_call({:index_document, doc, embedding}, _from, %{module: mod, state: state} = s) do
    case mod.index_document(doc, embedding, state) do
      {:ok, new_state} -> {:reply, :ok, %{s | state: new_state}}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:delete_document, doc_id}, _from, %{module: mod, state: state} = s) do
    case mod.delete_document(doc_id, state) do
      {:ok, new_state} -> {:reply, :ok, %{s | state: new_state}}
      :ok -> {:reply, :ok, s}
      error -> {:reply, error, s}
    end
  end

  def handle_call({:find_candidates, query_embedding, opts}, _from, %{module: mod, state: state} = s) do
    result = mod.find_candidates(query_embedding, opts, state)
    {:reply, result, s}
  end

  def handle_call(:get_stats, _from, %{module: mod, state: state} = s) do
    stats = mod.get_stats(state)
    {:reply, stats, s}
  end

  def handle_call(:optimize, _from, %{module: mod, state: state} = s) do
    if function_exported?(mod, :optimize, 1) do
      case mod.optimize(state) do
        {:ok, new_state} -> {:reply, :ok, %{s | state: new_state}}
        error -> {:reply, error, s}
      end
    else
      {:reply, {:error, :not_supported}, s}
    end
  end
end

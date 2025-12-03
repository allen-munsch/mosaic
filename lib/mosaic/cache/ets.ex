defmodule Mosaic.Cache.ETS do
  @moduledoc """
  An ETS-based cache implementation that conforms to the `Mosaic.Cache` behaviour.
  """
  use GenServer
  require Logger

  @behaviour Mosaic.Cache

  @cleanup_interval :timer.minutes(1)

  # Server API
  @impl Mosaic.Cache
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, __MODULE__)
    :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table_name}}
  end

  # Client API
  @impl Mosaic.Cache
  def get(key, name \\__MODULE__) do
    GenServer.call(name, {:get, key})
  end

  @impl Mosaic.Cache
  def put(key, value, ttl, name \\__MODULE__) do
    GenServer.call(name, {:put, key, value, ttl})
  end

  @impl Mosaic.Cache
  def delete(key, name \\__MODULE__) do
    GenServer.call(name, {:delete, key})
  end

  @impl Mosaic.Cache
  def clear(name \\__MODULE__) do
    GenServer.call(name, :clear)
  end

  @impl true
  def get_many(keys, name \\__MODULE__) do
    GenServer.call(name, {:get_many, keys})
  end

  @impl true
  def put_many(entries, ttl, name \\__MODULE__) do
    GenServer.call(name, {:put_many, entries, ttl})
  end

  # Server Callbacks
  @impl true
  def handle_call({:get, key}, _from, state) do
    reply =
      case :ets.lookup(state.table, key) do
        [{^key, value, expires_at}] ->
          if expires_at == :infinity or expires_at > System.system_time(:second) do
            {:ok, value}
          else
            :ets.delete(state.table, key)
            :miss
          end
        [] ->
          :miss
      end
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:put, key, value, ttl}, _from, state) do
    expires_at =
      case ttl do
        :infinity -> :infinity
        seconds -> System.system_time(:second) + seconds
      end
    :ets.insert(state.table, {key, value, expires_at})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

 @impl true
def handle_call({:get_many, keys}, _from, state) do
  now = System.system_time(:second)
  results = Enum.reduce(keys, %{}, fn key, acc ->
    case :ets.lookup(state.table, key) do
      [{^key, value, exp}] when exp == :infinity or exp > now -> Map.put(acc, key, value)
      _ -> acc
    end
  end)
  {:reply, results, state}
end

 @impl true
def handle_call({:put_many, entries, ttl}, _from, state) do
  expires_at = case ttl do
    :infinity -> :infinity
    seconds -> System.system_time(:second) + seconds
  end
  Enum.each(entries, fn {key, value} -> :ets.insert(state.table, {key, value, expires_at}) end)
  {:reply, :ok, state}
end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(state.table, [{{:_, :_, :""}, [{:"/=", :"", :infinity}, {:<, :"", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
defmodule Mosaic.Cache.Redis do
  @moduledoc """
  A Redis-based cache implementation that conforms to the `Mosaic.Cache` behaviour.
  """
  use GenServer
  require Logger

  @behaviour Mosaic.Cache

  @impl Mosaic.Cache
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :url, "redis://localhost:6379")
    {:ok, conn} = Redix.start_link(url)
    {:ok, %{conn: conn}}
  end

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
  def handle_call({:get, key}, _from, %{conn: conn} = state) do
    result =
      case Redix.command(conn, ["GET", key]) do
        {:ok, nil} -> :miss
        {:ok, value} -> {:ok, Jason.decode!(value)}
        {:error, _} = err -> err
      end
    {:reply, result, state}
  end

  @impl true
  def handle_call({:put, key, value, ttl}, _from, %{conn: conn} = state) do
    encoded = Jason.encode!(value)
    result =
      case ttl do
        :infinity -> Redix.command(conn, ["SET", key, encoded])
        seconds -> Redix.command(conn, ["SETEX", key, seconds, encoded])
      end
    {:reply, normalize_result(result), state}
  end

  @impl true
  def handle_call({:delete, key}, _from, %{conn: conn} = state) do
    result = Redix.command(conn, ["DEL", key])
    {:reply, normalize_result(result), state}
  end

  @impl true
  def handle_call(:clear, _from, %{conn: conn} = state) do
    result = Redix.command(conn, ["FLUSHDB"])
    {:reply, normalize_result(result), state}
  end

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, _} = err), do: err
end
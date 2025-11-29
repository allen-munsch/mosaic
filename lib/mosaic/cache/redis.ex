defmodule Mosaic.Cache.Redis do
  @behaviour Mosaic.Cache
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    url = Keyword.get(opts, :url, "redis://localhost:6379")
    {:ok, conn} = Redix.start_link(url)
    {:ok, %{conn: conn}}
  end

  @impl true
  def get(key, name \\__MODULE__) do
    GenServer.call(name, {:get, key})
  end

  @impl true
  def put(key, value, ttl, name \\__MODULE__) do
    GenServer.call(name, {:put, key, value, ttl})
  end

  @impl true
  def delete(key, name \\__MODULE__) do
    GenServer.call(name, {:delete, key})
  end

  @impl true
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
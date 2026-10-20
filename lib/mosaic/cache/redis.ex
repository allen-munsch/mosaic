defmodule Mosaic.Cache.Redis do
  @moduledoc """
  A Redis-based cache implementation that conforms to the `Mosaic.Cache` behaviour.
  """
  use GenServer

  @behaviour Mosaic.Cache

  @impl Mosaic.Cache
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  @spec init(keyword()) :: {:ok, %{conn: pid()}}
  def init(opts) do
    url = Keyword.get(opts, :url, "redis://localhost:6379")
    {:ok, conn} = Redix.start_link(url)
    {:ok, %{conn: conn}}
  end

  @impl Mosaic.Cache
  @spec get(term(), atom()) :: {:ok, term()} | :miss | {:error, term()}
  def get(key, name \\__MODULE__) do
    GenServer.call(name, {:get, key})
  end

  @impl Mosaic.Cache
  @spec put(term(), term(), non_neg_integer() | :infinity, atom()) :: :ok | {:error, term()}
  def put(key, value, ttl, name \\__MODULE__) do
    GenServer.call(name, {:put, key, value, ttl})
  end

  @impl Mosaic.Cache
  @spec delete(term(), atom()) :: :ok | {:error, term()}
  def delete(key, name \\__MODULE__) do
    GenServer.call(name, {:delete, key})
  end

  @impl Mosaic.Cache
  @spec clear(atom()) :: :ok | {:error, term()}
  def clear(name \\__MODULE__) do
    GenServer.call(name, :clear)
  end

  @impl Mosaic.Cache
  @spec get_many([term()], atom()) :: %{term() => term()}
  def get_many(keys, name \\ __MODULE__), do: GenServer.call(name, {:get_many, keys})

  @impl Mosaic.Cache
  @spec put_many([{term(), term()}], non_neg_integer() | :infinity, atom()) :: :ok
  def put_many(entries, ttl, name \\ __MODULE__), do: GenServer.call(name, {:put_many, entries, ttl})

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
  def handle_call({:get_many, keys}, _from, %{conn: conn} = state) do
    results = Enum.reduce(keys, %{}, fn key, acc ->
      case Redix.command(conn, ["GET", key]) do
        {:ok, nil} -> acc
        {:ok, val} -> Map.put(acc, key, Jason.decode!(val))
        _ -> acc
      end
    end)
    {:reply, results, state}
  end

  @impl true
  def handle_call({:put_many, entries, ttl}, _from, %{conn: conn} = state) do
    Enum.each(entries, fn {key, value} ->
      encoded = Jason.encode!(value)
      case ttl do
        :infinity -> Redix.command(conn, ["SET", key, encoded])
        seconds -> Redix.command(conn, ["SETEX", key, seconds, encoded])
      end
    end)
    {:reply, :ok, state}
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

defmodule Mosaic.ShardRouter.Worker do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  def init(_), do: {:ok, %{}}

def handle_call({:find_similar, query_vector, limit, opts, router_state}, _from, worker_state) do
  {shards, cache_hit} = Mosaic.ShardRouter.do_find_similar(query_vector, limit, opts, router_state)
  {:reply, {shards, cache_hit}, worker_state}
end
end


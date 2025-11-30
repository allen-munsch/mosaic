defmodule Mosaic.ShardRouter.Worker do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  def init(_), do: {:ok, %{}}

  def handle_call({:find_similar, query_vector, limit, opts, state}, _from, worker_state) do
    # This will call a new internal function in ShardRouter that does the actual work
    {shards, cache_hit} = Mosaic.ShardRouter.do_find_similar(query_vector, limit, opts, state)
    {:reply, {shards, cache_hit}, worker_state}
  end
end


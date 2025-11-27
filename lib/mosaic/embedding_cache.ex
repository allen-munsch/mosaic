defmodule Mosaic.EmbeddingCache do
  use GenServer
  require Logger

  defmodule State do
    defstruct [:cache, :lru_queue, :max_size, :cache_hits, :cache_misses]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    max_size = Mosaic.Config.get(:embedding_cache_max_size)
    state = %State{
      cache: %{},
      lru_queue: :queue.new(),
      max_size: max_size,
      cache_hits: 0,
      cache_misses: 0
    }
    
    {:ok, state}
  end

  def get(text), do: GenServer.call(__MODULE__, {:get, text})
  def put(text, embedding), do: GenServer.cast(__MODULE__, {:put, text, embedding})
  def get_metrics(), do: GenServer.call(__MODULE__, :get_metrics)
  def reset_state(), do: GenServer.call(__MODULE__, :reset_state)

  def handle_call({:get, text}, _from, state) do
    key = hash_text(text)
    case Map.get(state.cache, key) do
      nil -> 
        {:reply, :miss, %{state | cache_misses: state.cache_misses + 1}}
      embedding ->
        # Update LRU: remove key from current position and re-add to the end
        new_lru_queue = do_move_to_end(state.lru_queue, key)

        {:reply, {:ok, embedding}, %{state | 
          cache_hits: state.cache_hits + 1,
          lru_queue: new_lru_queue
        }}
    end
  end

  def handle_call(:get_metrics, _from, state) do
    {:reply, %{hits: state.cache_hits, misses: state.cache_misses}, state}
  end

  def handle_call(:reset_state, _from, _state) do
    max_size = Mosaic.Config.get(:embedding_cache_max_size)
    new_state = %State{
      cache: %{},
      lru_queue: :queue.new(),
      max_size: max_size,
      cache_hits: 0,
      cache_misses: 0
    }
    {:reply, :ok, new_state}
  end

  def handle_cast({:put, text, embedding}, state) do
    key = hash_text(text)
    
    # Evict if necessary
    new_state = if map_size(state.cache) >= state.max_size and not Map.has_key?(state.cache, key) do
      evict_lru(state)
    else
      state
    end
    
    # Remove existing key from LRU queue if present.
    cleaned_queue = if :queue.is_empty(new_state.lru_queue) do
      new_state.lru_queue
    else
      :queue.to_list(new_state.lru_queue)
      |> Enum.filter(fn item -> item != key end)
      |> :queue.from_list()
    end
    
    # Add to cache
    new_cache = Map.put(new_state.cache, key, embedding)
    new_queue = :queue.in(key, cleaned_queue) # Add to the cleaned queue
    
    {:noreply, %{new_state | 
      cache: new_cache, 
      lru_queue: new_queue
    }}
  end

  defp evict_lru(state) do
    case :queue.out(state.lru_queue) do
      {{:value, key_to_evict}, new_queue} ->
        %{state |
          cache: Map.delete(state.cache, key_to_evict),
          lru_queue: new_queue
        }
      {:empty, _} ->
        state # Should not happen if map_size(state.cache) >= max_size
    end
  end

  # Helper function to move an item to the end of the queue (LRU update)
  defp do_move_to_end(queue, item_to_move) do
    # Convert to list, filter, then convert back to queue
    cleaned_list = :queue.to_list(queue) |> Enum.filter(fn item -> item != item_to_move end)
    # Add to the end
    :queue.in(item_to_move, :queue.from_list(cleaned_list))
  end

  defp hash_text(text) do
    :crypto.hash(:sha256, text) |> Base.encode16()
  end
end
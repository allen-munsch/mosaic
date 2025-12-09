defmodule Mosaic.Index.Strategy.Quantized do
  @behaviour Mosaic.Index.Strategy
  require Logger
  
  alias Mosaic.Index.Quantized.{Cell, PathEncoder, CellRegistry}
  
  defstruct [:base_path, :dim, :bins, :dims_per_level, :cell_capacity, :search_radius]
  
  @impl true
  def init(opts) do
    config = %__MODULE__{
      base_path: Keyword.get(opts, :base_path, Path.join(Mosaic.Config.get(:storage_path), "quantized_index")),
      dim: Keyword.get(opts, :dim, Mosaic.Config.get(:embedding_dim)),
      bins: Keyword.get(opts, :bins, Mosaic.Config.get(:quantized_bins)),
      dims_per_level: Keyword.get(opts, :dims_per_level, Mosaic.Config.get(:quantized_dims_per_level)),
      cell_capacity: Keyword.get(opts, :cell_capacity, Mosaic.Config.get(:quantized_cell_capacity)),
      search_radius: Keyword.get(opts, :search_radius, Mosaic.Config.get(:quantized_search_radius))
    }
    
    # Start the CellRegistry as part of the state initialization
    {:ok, _pid} = CellRegistry.start_link(config)
    {:ok, config}
  end
  
  @impl true
  def index_document(doc, embedding, state) do
    quantized_path = PathEncoder.encode(embedding, state)
    # CellRegistry.get_or_create actually returns the PID of the GenServer for the cell
    cell_pid = CellRegistry.get_or_create(quantized_path, state)
    Cell.insert(cell_pid, doc.id, embedding, doc.metadata)
  end

  @impl true
  def delete_document(_doc_id, _state) do
    # This is more complex for a quantized index as the doc could be in multiple cells
    # For now, we'll implement a basic version that assumes we know the cell path
    # or requires iterating through cells (which is not efficient).
    # A more robust solution would involve storing doc_id -> cell_path mapping.
    # For this refactoring, we'll leave it as a placeholder or simplified approach.
    Logger.warning("Quantized strategy does not efficiently support deleting documents by ID without knowing cell path.")
    # To implement this properly, we'd need to modify the index_document to store doc_id -> quantized_path mapping
    # For now, assuming deletion isn't a primary requirement for the initial quantized strategy.
    {:error, "Delete not fully implemented for quantized strategy"}
  end
  
  @impl true
  def find_candidates(query_embedding, opts, state) do
    radius = Keyword.get(opts, :search_radius, state.search_radius)
    limit = Keyword.get(opts, :limit, 20)
    
    query_embedding
    |> PathEncoder.get_neighbor_paths(radius, state)
    |> Enum.flat_map(fn quantized_path ->
      cell_pid = CellRegistry.get_or_create(quantized_path, state)
      case Cell.search(cell_pid, query_embedding, limit) do
        {:ok, results} -> results
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)
    |> then(&{:ok, &1})
  end

  @impl true
  def get_stats(state) do
    # Placeholder: In a real scenario, this would aggregate stats from all active cells
    %{
      strategy: "quantized",
      base_path: state.base_path,
      num_cells: 0 # To be implemented
    }
  end
end

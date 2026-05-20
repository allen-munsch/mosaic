defmodule Mosaic.Index.HNSW.Graph do
  @moduledoc "High-level HNSW graph operations"
  

  
  def empty do
    %{layers: %{}, entry_point: nil}
  end
  
  def layer_count(%{layers: layers}), do: map_size(layers)
  def node_count(%{layers: layers}) do
    case Map.get(layers, 0) do
      nil -> 0
      layer -> map_size(layer.nodes)
    end
  end
end

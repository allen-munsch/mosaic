defmodule Mosaic.Index.HNSW.Layer do
  @moduledoc "Represents a single layer in the HNSW graph"
  
  alias Mosaic.Index.HNSW.Node
  
  defstruct [:nodes, :connections]
  
  @type t :: %__MODULE__{
    nodes: %{String.t() => Node.t()},
    connections: %{String.t() => MapSet.t()}
  }
  
  def new do
    %__MODULE__{nodes: %{}, connections: %{}}
  end
  
  def add_node(%__MODULE__{} = layer, %Node{} = node) do
    %{layer | 
      nodes: Map.put(layer.nodes, node.id, node),
      connections: Map.put_new(layer.connections, node.id, MapSet.new())
    }
  end
  
  def remove_node(%__MODULE__{} = layer, node_id) do
    # Remove node and all references to it
    new_connections = layer.connections
    |> Map.delete(node_id)
    |> Enum.map(fn {id, neighbors} -> {id, MapSet.delete(neighbors, node_id)} end)
    |> Map.new()
    
    %{layer |
      nodes: Map.delete(layer.nodes, node_id),
      connections: new_connections
    }
  end
  
  def get_node(%__MODULE__{} = layer, node_id) do
    Map.get(layer.nodes, node_id)
  end
  
  def get_any_node(%__MODULE__{nodes: nodes}) when map_size(nodes) == 0, do: nil
  def get_any_node(%__MODULE__{nodes: nodes}) do
    {_id, node} = Enum.at(nodes, 0)
    node
  end
  
  def get_neighbors(%__MODULE__{} = layer, node_id) do
    layer.connections
    |> Map.get(node_id, MapSet.new())
    |> MapSet.to_list()
  end
  
  def connect(%__MODULE__{} = layer, from_id, to_ids) when is_list(to_ids) do
    new_connections = Enum.reduce(to_ids, layer.connections, fn to_id, conns ->
      conns
      |> Map.update(from_id, MapSet.new([to_id]), &MapSet.put(&1, to_id))
      |> Map.update(to_id, MapSet.new([from_id]), &MapSet.put(&1, from_id))
    end)
    %{layer | connections: new_connections}
  end
  
  def shrink_connections(%__MODULE__{} = layer, node_id, max_connections) do
    case Map.get(layer.connections, node_id) do
      nil -> layer
      neighbors when is_struct(neighbors, MapSet) ->
        if MapSet.size(neighbors) <= max_connections do
          layer
        else
          node = get_node(layer, node_id)
          if node do
            # Keep closest neighbors
            sorted = neighbors
            |> MapSet.to_list()
            |> Enum.map(fn n_id -> {n_id, get_node(layer, n_id)} end)
            |> Enum.filter(fn {_, n} -> n != nil end)
            |> Enum.sort_by(fn {_, n} -> 
              Enum.zip(node.vector, n.vector)
              |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - b) * (a - b) end)
            end)
            |> Enum.take(max_connections)
            |> Enum.map(fn {id, _} -> id end)
            |> MapSet.new()
            
            %{layer | connections: Map.put(layer.connections, node_id, sorted)}
          else
            layer
          end
        end
    end
  end
  
  def optimize_connections(%__MODULE__{} = layer, m, _distance_fn) do
    # Rebuild all connections with optimal neighbor selection
    Enum.reduce(Map.keys(layer.nodes), layer, fn node_id, acc ->
      shrink_connections(acc, node_id, m)
    end)
  end
end

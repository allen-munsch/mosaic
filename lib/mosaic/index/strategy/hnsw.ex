defmodule Mosaic.Index.Strategy.HNSW do
  @moduledoc """
  Hierarchical Navigable Small World (HNSW) index strategy.
  
  Provides logarithmic search complexity with high recall.
  Based on: https://arxiv.org/abs/1603.09320
  
  Configuration:
  - :m - Max connections per node (default: 16)
  - :ef_construction - Size of dynamic candidate list during construction (default: 200)
  - :ef_search - Size of dynamic candidate list during search (default: 50)
  - :max_level - Maximum layer (auto-calculated if nil)
  - :distance_fn - :cosine | :euclidean | :dot (default: :cosine)
  """
  
  @behaviour Mosaic.Index.Strategy
  require Logger
  
  alias Mosaic.Index.HNSW.{Node, Layer}
  
  defstruct [
    :base_path,
    :m,
    :ef_construction,
    :ef_search,
    :max_level,
    :ml,
    :distance_fn,
    :entry_point,
    :layers,
    :node_count,
    :dim
  ]
  
  @default_m 16
  @default_ef_construction 200
  @default_ef_search 50
  
  @impl true
  def init(opts) do
    m = Keyword.get(opts, :m, @default_m)
    _m_max0 = m * 2
    ml = 1 / :math.log(m)
    
    config = %__MODULE__{
      base_path: Keyword.get(opts, :base_path, Path.join(Mosaic.Config.get(:storage_path), "hnsw_index")),
      m: m,
      ef_construction: Keyword.get(opts, :ef_construction, @default_ef_construction),
      ef_search: Keyword.get(opts, :ef_search, @default_ef_search),
      max_level: Keyword.get(opts, :max_level),
      ml: ml,
      distance_fn: Keyword.get(opts, :distance_fn, :cosine),
      entry_point: nil,
      layers: %{},
      node_count: 0,
      dim: Keyword.get(opts, :dim, Mosaic.Config.get(:embedding_dim))
    }
    
    File.mkdir_p!(config.base_path)
    
    # Try to load existing index
    case load_from_disk(config.base_path) do
      {:ok, loaded_state} -> {:ok, loaded_state}
      {:error, :not_found} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def index_document(doc, embedding, state) do
    node_level = random_level(state.ml, state.max_level)
    node = %Node{
      id: doc.id,
      vector: embedding,
      level: node_level,
      neighbors: %{},
      metadata: doc.metadata
    }
    
    new_state = insert_node(node, state)
    {:ok, new_state}
  end
  
  @impl true
  def index_batch(docs, state) do
    Enum.reduce_while(docs, {:ok, state}, fn {doc, embedding}, {:ok, acc} ->
      case index_document(doc, embedding, acc) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        error -> {:halt, error}
      end
    end)
  end
  
  @impl true
  def delete_document(doc_id, state) do
    new_layers = Enum.reduce(state.layers, %{}, fn {level, layer}, acc ->
      new_layer = Layer.remove_node(layer, doc_id)
      Map.put(acc, level, new_layer)
    end)
    
    new_entry_point = if state.entry_point && state.entry_point.id == doc_id do
      find_new_entry_point(new_layers)
    else
      state.entry_point
    end
    
    {:ok, %{state | layers: new_layers, entry_point: new_entry_point, node_count: state.node_count - 1}}
  end
  
  @impl true
  def find_candidates(query_embedding, opts, state) do
    if state.entry_point == nil do
      {:ok, []}
    else
      ef = Keyword.get(opts, :ef_search, state.ef_search)
      limit = Keyword.get(opts, :limit, 20)
      
      candidates = search_layer(
        query_embedding,
        state.entry_point,
        ef,
        0,
        state
      )
      
      results = candidates
      |> Enum.map(fn {node, dist} ->
        %{
          id: node.id,
          similarity: distance_to_similarity(dist, state.distance_fn),
          metadata: node.metadata,
          vector: node.vector
        }
      end)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)
      
      {:ok, results}
    end
  end
  
  @impl true
  def get_stats(state) do
    %{
      strategy: :hnsw,
      node_count: state.node_count,
      layer_count: map_size(state.layers),
      m: state.m,
      ef_construction: state.ef_construction,
      ef_search: state.ef_search,
      entry_point_id: state.entry_point && state.entry_point.id
    }
  end
  
  @impl true
  def serialize(state) do
    data = :erlang.term_to_binary(state)
    {:ok, data}
  end
  
  @impl true
  def deserialize(data, _opts) do
    state = :erlang.binary_to_term(data)
    {:ok, state}
  end
  
  @impl true
  def optimize(state) do
    # Rebuild connections for better search performance
    optimized_layers = Enum.reduce(state.layers, %{}, fn {level, layer}, acc ->
      optimized = Layer.optimize_connections(layer, state.m, state.distance_fn)
      Map.put(acc, level, optimized)
    end)
    {:ok, %{state | layers: optimized_layers}}
  end
  
  # Private functions
  
  defp random_level(ml, max_level) do
    level = trunc(-:math.log(:rand.uniform()) * ml)
    if max_level, do: min(level, max_level), else: level
  end
  
  defp insert_node(node, %{entry_point: nil} = state) do
    layer = Layer.new() |> Layer.add_node(node)
    %{state | 
      entry_point: node,
      layers: %{0 => layer},
      node_count: 1
    }
  end
  
  defp insert_node(node, state) do
    current_level = if state.entry_point, do: state.entry_point.level, else: 0
    
    # Find entry point for the insertion level
    {ep, state} = if node.level > current_level do
      {node, update_entry_point(state, node)}
    else
      {state.entry_point, state}
    end
    
    # Greedy search from top to node.level + 1
    ep = greedy_search_to_level(state, ep, node.vector, node.level + 1)
    
    # Insert at each level from node.level down to 0
    new_layers = Enum.reduce(node.level..0, state.layers, fn level, layers ->
      layer = Map.get(layers, level, Layer.new())
      
      # Find ef_construction nearest neighbors
      neighbors = search_layer_internal(
        node.vector,
        ep,
        state.ef_construction,
        level,
        state
      )
      
      # Select M best neighbors
      selected = select_neighbors(neighbors, state.m, state.distance_fn)
      
      # Add bidirectional connections
      updated_layer = layer
      |> Layer.add_node(node)
      |> Layer.connect(node.id, Enum.map(selected, fn {n, _} -> n.id end))
      
      # Shrink connections if needed
      updated_layer = Enum.reduce(selected, updated_layer, fn {neighbor, _dist}, l ->
        Layer.shrink_connections(l, neighbor.id, state.m * 2)
      end)
      
      Map.put(layers, level, updated_layer)
    end)
    
    %{state | layers: new_layers, node_count: state.node_count + 1}
  end
  
  defp greedy_search_to_level(state, entry_point, query, target_level) do
    Enum.reduce((entry_point.level)..(target_level + 1), entry_point, fn level, ep ->
      {[{closest, _} | _], _} = search_layer_internal(query, ep, 1, level, state)
      closest
    end)
  end
  
  defp search_layer(query, entry_point, ef, level, state) do
    search_layer_internal(query, entry_point, ef, level, state)
    |> elem(0)
  end
  
  defp search_layer_internal(query, entry_point, ef, level, state) do
    layer = Map.get(state.layers, level, Layer.new())
    
    visited = MapSet.new([entry_point.id])
    candidates = :gb_sets.singleton({distance(query, entry_point.vector, state.distance_fn), entry_point})
    results = :gb_sets.singleton({distance(query, entry_point.vector, state.distance_fn), entry_point})
    
    search_loop(query, candidates, results, visited, ef, layer, state)
  end
  
  defp search_loop(query, candidates, results, visited, ef, layer, state) do
    if :gb_sets.is_empty(candidates) do
      {results |> :gb_sets.to_list() |> Enum.map(fn {d, n} -> {n, d} end), visited}
    else
      {{c_dist, c_node}, rest_candidates} = :gb_sets.take_smallest(candidates)
      {f_dist, _f_node} = :gb_sets.largest(results)
      
      if c_dist > f_dist do
        {results |> :gb_sets.to_list() |> Enum.map(fn {d, n} -> {n, d} end), visited}
      else
        neighbor_ids = Layer.get_neighbors(layer, c_node.id)
        
        {new_candidates, new_results, new_visited} = 
          Enum.reduce(neighbor_ids, {rest_candidates, results, visited}, fn n_id, {cands, res, vis} ->
            if MapSet.member?(vis, n_id) do
              {cands, res, vis}
            else
              new_vis = MapSet.put(vis, n_id)
              case Layer.get_node(layer, n_id) do
                nil -> {cands, res, new_vis}
                neighbor ->
                  n_dist = distance(query, neighbor.vector, state.distance_fn)
                  {f_d, _} = :gb_sets.largest(res)
                  
                  if n_dist < f_d or :gb_sets.size(res) < ef do
                    new_cands = :gb_sets.add({n_dist, neighbor}, cands)
                    new_res = :gb_sets.add({n_dist, neighbor}, res)
                    new_res = if :gb_sets.size(new_res) > ef do
                      {_, trimmed} = :gb_sets.take_largest(new_res)
                      trimmed
                    else
                      new_res
                    end
                    {new_cands, new_res, new_vis}
                  else
                    {cands, res, new_vis}
                  end
              end
            end
          end)
        
        search_loop(query, new_candidates, new_results, new_visited, ef, layer, state)
      end
    end
  end
  
  defp select_neighbors(candidates, m, _distance_fn) do
    candidates
    |> Enum.sort_by(fn {_, dist} -> dist end)
    |> Enum.take(m)
  end
  
  defp update_entry_point(state, node) do
    %{state | entry_point: node}
  end
  
  defp find_new_entry_point(layers) do
    max_level = layers |> Map.keys() |> Enum.max(fn -> 0 end)
    case Map.get(layers, max_level) do
      nil -> nil
      layer -> Layer.get_any_node(layer)
    end
  end
  
  defp distance(v1, v2, :cosine) do
    1.0 - cosine_similarity(v1, v2)
  end
  
  defp distance(v1, v2, :euclidean) do
    v1
    |> Enum.zip(v2)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - b) * (a - b) end)
    |> :math.sqrt()
  end
  
  defp distance(v1, v2, :dot) do
    -Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
  end
  
  defp cosine_similarity(v1, v2) do
    dot = Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(v1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(v2, 0.0, fn x, acc -> acc + x * x end))
    dot / (norm1 * norm2 + 1.0e-10)
  end
  
  defp distance_to_similarity(dist, :cosine), do: 1.0 - dist
  defp distance_to_similarity(dist, :euclidean), do: 1.0 / (1.0 + dist)
  defp distance_to_similarity(dist, :dot), do: -dist
  
  defp load_from_disk(base_path) do
    index_file = Path.join(base_path, "index.bin")
    if File.exists?(index_file) do
      case File.read(index_file) do
        {:ok, data} -> deserialize(data, [])
        error -> error
      end
    else
      {:error, :not_found}
    end
  end
end

defmodule Mosaic.Index.Quantized.PathEncoder do
  @moduledoc """
  Convert vector to directory path via quantization
  """
  def encode(vector, config) do
    normalized = normalize(vector)
    num_levels = ceil(config.dim / config.dims_per_level)
    
    0..(num_levels - 1)
    |> Enum.map(fn level ->
      start_idx = level * config.dims_per_level
      end_idx = min(start_idx + config.dims_per_level, config.dim)
      slice = Enum.slice(normalized, start_idx..(end_idx - 1))
      bin_idx = trunc(Enum.sum(slice) / length(slice) * (config.bins - 1))
      String.pad_leading("#{bin_idx}", 3, "0")
    end)
    |> Enum.join("/")
  end
  
  def get_neighbor_paths(embedding, radius, config) do
    base_path = encode(embedding, config)
    expand_neighbors(base_path, radius, config.bins)
  end
  
  defp normalize(vector) do
    {min_v, max_v} = Enum.min_max(vector)
    range = max_v - min_v + 1.0e-8
    Enum.map(vector, &((&1 - min_v) / range))
  end
  
  defp expand_neighbors(path, 0, _bins), do: [path]
  defp expand_neighbors(path, radius, bins) do
    parts = String.split(path, "/")
    
    # Generate all combinations within radius
    parts
    |> Enum.with_index()
    |> Enum.reduce([[]], fn {part, _idx}, acc ->
      bin = String.to_integer(part)
      neighbors = for offset <- -radius..radius, 
                      new_bin = bin + offset,
                      new_bin >= 0 and new_bin < bins,
                      do: String.pad_leading("#{new_bin}", 3, "0")
      
      for prev <- acc, n <- neighbors, do: prev ++ [n]
    end)
    |> Enum.map(&Enum.join(&1, "/"))
  end
end

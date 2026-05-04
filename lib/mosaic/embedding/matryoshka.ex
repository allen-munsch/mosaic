defmodule Mosaic.Embedding.Matryoshka do
  @moduledoc """
  Matryoshka embedding utilities: multi-level truncation and model selection.

  Matryoshka Representation Learning (Kusupati et al., 2022) produces embeddings
  where the first `k` dimensions form a valid lower-resolution embedding. This
  enables cascaded search: scan coarsely at 64d, refine at 128d, score at 768d.

  ## Usage

      iex> full = Matryoshka.encode("def handle_call(...)")
      [0.023, -0.451, ...]  # 768 dimensions

      iex> coarse = Matryoshka.truncate(full, 64)
      [0.023, -0.451, ...]  # first 64 dimensions only

      iex> Matryoshka.levels()
      [64, 128, 256, 384]
  """

  @doc """
  Truncate an embedding to `dims` dimensions.
  Returns the first `dims` elements of the embedding vector.
  """
  def truncate(embedding, dims) when is_list(embedding) do
    Enum.take(embedding, dims)
  end

  @doc """
  Truncate an embedding binary (float32 little-endian) to `dims` dimensions.
  Returns a binary of the first `dims * 4` bytes.
  """
  def truncate_binary(binary, dims) when is_binary(binary) do
    byte_count = dims * 4
    <<head::binary-size(^byte_count), _rest::binary>> = binary
    head
  end

  @doc """
  Encode text to the full-dimension embedding, then truncate to each
  level. Returns a map of level → embedding.

      iex> Matryoshka.encode_levels("some text")
      %{64 => [...], 128 => [...], 256 => [...], 384 => [...]}
  """
  def encode_levels(text) do
    full = Mosaic.EmbeddingService.encode(text)
    levels = Mosaic.Config.get(:matryoshka_levels, [64, 128, 256, 384])

    Map.new(levels, fn dims ->
      truncated = truncate(full, dims)
      {dims, truncated}
    end)
  end

  @doc """
  Encode a batch of texts, returning full-dimension embeddings.
  Uses the configured embedding service.
  """
  def encode_batch(texts) when is_list(texts) do
    Mosaic.EmbeddingService.encode_batch(texts)
  end

  @doc """
  Encode batch and produce all matryoshka levels for each text.
  Returns list of maps: [%{full: [...], 256: [...], 128: [...], 64: [...]}, ...]
  """
  def encode_batch_levels(texts) when is_list(texts) do
    full_embeddings = encode_batch(texts)
    levels = Mosaic.Config.get(:matryoshka_levels, [64, 128, 256, 384])

    Enum.map(full_embeddings, fn full ->
      level_map = Map.new(levels, fn dims ->
        {dims, truncate(full, dims)}
      end)
      Map.put(level_map, :full, full)
    end)
  end

  @doc "List configured matryoshka dimension levels, smallest first."
  def levels do
    Mosaic.Config.get(:matryoshka_levels, [64, 128, 256, 384])
  end

  @doc "Get the coarsest (smallest) level dimension."
  def coarse_level do
    Mosaic.Config.get(:matryoshka_coarse_level, 64)
  end

  @doc "Get the finest (largest) level dimension."
  def fine_level do
    Mosaic.Config.get(:matryoshka_fine_level, 384)
  end

  @doc """
  Get the cascade multiplier for a given level.
  Returns how many candidates to fetch at this level relative to the target limit.
  e.g., at 64d, fetch limit * 50 candidates for wide recall.
  """
  def cascade_factor(level) do
    Mosaic.Config.get(:matryoshka_cascade_factors, %{64 => 50, 128 => 10, 256 => 3})
    |> Map.get(level, 5)
  end

  @doc """
  Get the vec table name for a given dimension level.
  e.g., `vec_nodes_64`, `vec_nodes_256`
  """
  def vec_table_name(dims) do
    :"vec_nodes_#{dims}"
  end

  @doc "Get the full-resolution vec table name."
  def full_table_name do
    dim = Mosaic.Config.get(:embedding_dim)
    :"vec_nodes_#{dim}"
  end

  @doc """
  Encode embedding list as a JSON string for sqlite-vec vec0 insertion.
  vec0 expects JSON arrays for embedding values.
  """
  def to_vec_json(embedding) when is_list(embedding) do
    Jason.encode!(embedding)
  end

  @doc """
  Encode embedding list as a binary float32 blob for storage.
  """
  def to_binary(embedding) when is_list(embedding) do
    for f <- embedding, into: <<>>, do: <<f::float-32-native>>
  end

  @doc """
  Decode binary float32 blob back to list.
  """
  def from_binary(binary) when is_binary(binary) do
    for <<f::float-32-native <- binary>>, do: f
  end
end

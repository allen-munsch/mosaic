defmodule Mosaic.Index.Strategy.PQ do
  @moduledoc """
  Product Quantization (PQ) strategy for compressed vector storage.

  Splits vectors into subspaces and quantizes each independently.
  Achieves high compression with good accuracy.

  Configuration:
  - :m - Number of subspaces (default: 8)
  - :k_sub - Centroids per subspace (default: 256)
  - :training_size - Vectors for codebook training (default: 10000)
  """

  @behaviour Mosaic.Index.Strategy
  require Logger

  defstruct [
    :base_path,
    :m,
    :k_sub,
    :dim,
    :sub_dim,
    :training_size,
    :codebooks,
    :codes,
    :training_buffer,
    :trained,
    :doc_count
  ]

  @default_m 8
  @default_k_sub 256
  @default_training_size 10000

  @impl true
  def init(opts) do
    dim = Keyword.get(opts, :dim, Mosaic.Config.get(:embedding_dim))
    m = Keyword.get(opts, :m, @default_m)

    if rem(dim, m) != 0 do
      {:error, "Dimension #{dim} must be divisible by m=#{m}"}
    else
      config = %__MODULE__{
        base_path: Keyword.get(opts, :base_path, Path.join(Mosaic.Config.get(:storage_path), "pq_index")),
        m: m,
        k_sub: Keyword.get(opts, :k_sub, @default_k_sub),
        dim: dim,
        sub_dim: div(dim, m),
        training_size: Keyword.get(opts, :training_size, @default_training_size),
        codebooks: nil,
        codes: %{},
        training_buffer: [],
        trained: false,
        doc_count: 0
      }

      File.mkdir_p!(config.base_path)
      {:ok, config}
    end
  end

  @impl true
  def index_document(doc, embedding, state) do
    if state.trained do
      # Encode vector using codebooks
      code = encode_vector(embedding, state.codebooks, state)

      entry = %{id: doc.id, code: code, metadata: doc.metadata}
      new_codes = Map.put(state.codes, doc.id, entry)

      {:ok, %{state | codes: new_codes, doc_count: state.doc_count + 1}}
    else
      new_buffer = [{doc, embedding} | state.training_buffer]

      if length(new_buffer) >= state.training_size do
        trained_state = train_codebooks(state, new_buffer)
        Enum.reduce(new_buffer, {:ok, trained_state}, fn {d, e}, {:ok, s} ->
          index_document(d, e, s)
        end)
      else
        {:ok, %{state | training_buffer: new_buffer}}
      end
    end
  end

  @impl true
  def delete_document(doc_id, state) do
    new_codes = Map.delete(state.codes, doc_id)
    {:ok, %{state | codes: new_codes, doc_count: state.doc_count - 1}}
  end

  @impl true
  def find_candidates(query_embedding, opts, state) do
    limit = Keyword.get(opts, :limit, 20)

    if not state.trained do
      search_buffer(query_embedding, opts, state)
    else
      # Precompute distances to all centroids for each subspace
      distance_tables = build_distance_tables(query_embedding, state.codebooks, state)

      # Compute asymmetric distances using lookup tables
      results = state.codes
      |> Enum.map(fn {_id, entry} ->
        dist = compute_asymmetric_distance(entry.code, distance_tables)
        %{id: entry.id, similarity: 1.0 / (1.0 + dist), metadata: entry.metadata}
      end)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)

      {:ok, results}
    end
  end

  @impl true
  def get_stats(state) do
    compression_ratio = if state.trained do
      original_bytes = state.dim * 4  # float32
      compressed_bytes = state.m  # 1 byte per subspace
      original_bytes / compressed_bytes
    else
      0
    end

    %{
      strategy: :pq,
      doc_count: state.doc_count,
      m: state.m,
      k_sub: state.k_sub,
      trained: state.trained,
      compression_ratio: compression_ratio,
      buffer_size: length(state.training_buffer)
    }
  end

  @impl true
  def serialize(state) do
    {:ok, :erlang.term_to_binary(state)}
  end

  @impl true
  def deserialize(data, _opts) do
    {:ok, :erlang.binary_to_term(data)}
  end

  # Private functions

  defp train_codebooks(state, buffer) do
    vectors = Enum.map(buffer, fn {_doc, embedding} -> embedding end)

    # Train a codebook for each subspace
    codebooks = 0..(state.m - 1)
    |> Enum.map(fn subspace_idx ->
      # Extract subvectors for this subspace
      subvectors = Enum.map(vectors, fn v ->
        start = subspace_idx * state.sub_dim
        Enum.slice(v, start, state.sub_dim)
      end)

      # Cluster subvectors
      kmeans_subspace(subvectors, state.k_sub)
    end)

    %{state |
      codebooks: codebooks,
      training_buffer: [],
      trained: true
    }
  end

  defp encode_vector(vector, codebooks, state) do
    0..(state.m - 1)
    |> Enum.map(fn subspace_idx ->
      subvector = Enum.slice(vector, subspace_idx * state.sub_dim, state.sub_dim)
      centroids = Enum.at(codebooks, subspace_idx)
      find_nearest_idx(subvector, centroids)
    end)
  end

  defp build_distance_tables(query_vector, codebooks, state) do
    0..(state.m - 1)
    |> Enum.map(fn subspace_idx ->
      query_sub = Enum.slice(query_vector, subspace_idx * state.sub_dim, state.sub_dim)
      centroids = Enum.at(codebooks, subspace_idx)

      Enum.map(centroids, fn centroid ->
        euclidean_distance_sq(query_sub, centroid)
      end)
    end)
  end

  defp compute_asymmetric_distance(code, distance_tables) do
    code
    |> Enum.zip(distance_tables)
    |> Enum.reduce(0.0, fn {centroid_idx, table}, acc ->
      acc + Enum.at(table, centroid_idx, 0.0)
    end)
    |> :math.sqrt()
  end

  defp kmeans_subspace(vectors, k, max_iterations \\ 50) do
    if length(vectors) < k do
      vectors ++ List.duplicate(hd(vectors), k - length(vectors))
    else
      centroids = vectors |> Enum.shuffle() |> Enum.take(k)
      iterate_kmeans_sub(vectors, centroids, max_iterations, 0)
    end
  end

  defp iterate_kmeans_sub(_vectors, centroids, max_iterations, iteration) when iteration >= max_iterations do
    centroids
  end

  defp iterate_kmeans_sub(vectors, centroids, max_iterations, iteration) do
    assignments = Enum.map(vectors, fn v -> find_nearest_idx(v, centroids) end)

    new_centroids = 0..(length(centroids) - 1)
    |> Enum.map(fn cluster_id ->
      cluster_vectors = vectors
      |> Enum.zip(assignments)
      |> Enum.filter(fn {_, a} -> a == cluster_id end)
      |> Enum.map(&elem(&1, 0))

      if Enum.empty?(cluster_vectors) do
        Enum.at(centroids, cluster_id)
      else
        compute_mean(cluster_vectors)
      end
    end)

    if centroids == new_centroids do
      new_centroids
    else
      iterate_kmeans_sub(vectors, new_centroids, max_iterations, iteration + 1)
    end
  end

  defp find_nearest_idx(vector, centroids) do
    centroids
    |> Enum.with_index()
    |> Enum.min_by(fn {centroid, _} -> euclidean_distance_sq(vector, centroid) end)
    |> elem(1)
  end

  defp compute_mean(vectors) do
    dim = length(hd(vectors))
    count = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, dim), fn v, acc ->
      Enum.zip(v, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / count))
  end

  defp euclidean_distance_sq(v1, v2) do
    Enum.zip(v1, v2)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - b) * (a - b) end)
  end

  defp search_buffer(query_embedding, opts, state) do
    limit = Keyword.get(opts, :limit, 20)

    results = state.training_buffer
    |> Enum.map(fn {doc, embedding} ->
      dist = :math.sqrt(euclidean_distance_sq(query_embedding, embedding))
      %{id: doc.id, similarity: 1.0 / (1.0 + dist), metadata: doc.metadata}
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)

    {:ok, results}
  end
end

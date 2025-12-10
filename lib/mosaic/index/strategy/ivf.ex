defmodule Mosaic.Index.Strategy.IVF do
  @moduledoc """
  Inverted File Index (IVF) strategy with k-means clustering.

  Partitions vectors into clusters for faster search.

  Configuration:
  - :n_lists - Number of clusters/inverted lists (default: 100)
  - :n_probe - Number of clusters to search (default: 10)
  - :training_size - Vectors needed before clustering (default: 1000)
  - :distance_fn - :cosine | :euclidean (default: :cosine)
  """

  @behaviour Mosaic.Index.Strategy
  require Logger

  defstruct [
    :base_path,
    :n_lists,
    :n_probe,
    :training_size,
    :distance_fn,
    :centroids,
    :inverted_lists,
    :training_buffer,
    :trained,
    :doc_count
  ]

  @default_n_lists 100
  @default_n_probe 10
  @default_training_size 1000

  @impl true
  def init(opts) do
    config = %__MODULE__{
      base_path: Keyword.get(opts, :base_path, Path.join(Mosaic.Config.get(:storage_path), "ivf_index")),
      n_lists: Keyword.get(opts, :n_lists, @default_n_lists),
      n_probe: Keyword.get(opts, :n_probe, @default_n_probe),
      training_size: Keyword.get(opts, :training_size, @default_training_size),
      distance_fn: Keyword.get(opts, :distance_fn, :cosine),
      centroids: [],
      inverted_lists: %{},
      training_buffer: [],
      trained: false,
      doc_count: 0
    }

    File.mkdir_p!(config.base_path)
    {:ok, config}
  end

  @impl true
  def index_document(doc, embedding, state) do
    if state.trained do
      # Find nearest centroid and add to inverted list
      cluster_id = find_nearest_centroid(embedding, state.centroids, state.distance_fn)

      entry = %{id: doc.id, vector: embedding, metadata: doc.metadata}
      new_lists = Map.update(
        state.inverted_lists,
        cluster_id,
        [entry],
        &[entry | &1]
      )

      {:ok, %{state | inverted_lists: new_lists, doc_count: state.doc_count + 1}}
    else
      # Buffer until we have enough for training
      new_buffer = [{doc, embedding} | state.training_buffer]

      if length(new_buffer) >= state.training_size do
        trained_state = train_centroids(state, new_buffer)
        # Index all buffered documents
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
    new_lists = Enum.reduce(state.inverted_lists, %{}, fn {cluster_id, entries}, acc ->
      filtered = Enum.filter(entries, fn e -> e.id != doc_id end)
      Map.put(acc, cluster_id, filtered)
    end)

    {:ok, %{state | inverted_lists: new_lists, doc_count: state.doc_count - 1}}
  end

  @impl true
  def find_candidates(query_embedding, opts, state) do
    if not state.trained or Enum.empty?(state.centroids) do
      # Search buffer if not trained yet
      search_buffer(query_embedding, opts, state)
    else
      limit = Keyword.get(opts, :limit, 20)
      n_probe = Keyword.get(opts, :n_probe, state.n_probe)

      # Find n_probe nearest clusters
      nearest_clusters = state.centroids
      |> Enum.with_index()
      |> Enum.map(fn {centroid, idx} ->
        {idx, distance(query_embedding, centroid, state.distance_fn)}
      end)
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(n_probe)
      |> Enum.map(&elem(&1, 0))

      # Search all vectors in those clusters
      results = nearest_clusters
      |> Enum.flat_map(fn cluster_id ->
        Map.get(state.inverted_lists, cluster_id, [])
      end)
      |> Enum.map(fn entry ->
        sim = similarity(query_embedding, entry.vector, state.distance_fn)
        %{id: entry.id, similarity: sim, metadata: entry.metadata}
      end)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)

      {:ok, results}
    end
  end

  @impl true
  def get_stats(state) do
    list_sizes = state.inverted_lists
    |> Enum.map(fn {_, entries} -> length(entries) end)

    %{
      strategy: :ivf,
      doc_count: state.doc_count,
      n_lists: state.n_lists,
      n_probe: state.n_probe,
      trained: state.trained,
      cluster_count: length(state.centroids),
      avg_list_size: if(Enum.empty?(list_sizes), do: 0, else: Enum.sum(list_sizes) / length(list_sizes)),
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

  @impl true
  def optimize(state) do
    # Retrain centroids if distribution changed significantly
    all_vectors = state.inverted_lists
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.vector)

    if length(all_vectors) > state.training_size do
      new_centroids = kmeans(all_vectors, min(state.n_lists, length(all_vectors)), state.distance_fn)

      # Reassign all vectors
      new_lists = Enum.reduce(Map.values(state.inverted_lists) |> List.flatten(), %{}, fn entry, acc ->
        cluster_id = find_nearest_centroid(entry.vector, new_centroids, state.distance_fn)
        Map.update(acc, cluster_id, [entry], &[entry | &1])
      end)

      {:ok, %{state | centroids: new_centroids, inverted_lists: new_lists}}
    else
      {:ok, state}
    end
  end

  # Private functions

  defp train_centroids(state, buffer) do
    vectors = Enum.map(buffer, fn {_doc, embedding} -> embedding end)
    centroids = kmeans(vectors, min(state.n_lists, length(vectors)), state.distance_fn)

    %{state |
      centroids: centroids,
      inverted_lists: Enum.reduce(0..(length(centroids) - 1), %{}, fn i, acc -> Map.put(acc, i, []) end),
      training_buffer: [],
      trained: true
    }
  end

  defp kmeans(vectors, k, distance_fn, max_iterations \\ 100) do
    _dim = length(hd(vectors))

    # Initialize centroids randomly
    initial_centroids = vectors |> Enum.shuffle() |> Enum.take(k)

    iterate_kmeans(vectors, initial_centroids, distance_fn, max_iterations, 0)
  end

  defp iterate_kmeans(_vectors, centroids, _distance_fn, max_iterations, iteration) when iteration >= max_iterations do
    centroids
  end

  defp iterate_kmeans(vectors, centroids, distance_fn, max_iterations, iteration) do
    # Assign vectors to clusters
    assignments = Enum.map(vectors, fn v ->
      find_nearest_centroid(v, centroids, distance_fn)
    end)

    # Compute new centroids
    new_centroids = 0..(length(centroids) - 1)
    |> Enum.map(fn cluster_id ->
      cluster_vectors = vectors
      |> Enum.zip(assignments)
      |> Enum.filter(fn {_, a} -> a == cluster_id end)
      |> Enum.map(&elem(&1, 0))

      if Enum.empty?(cluster_vectors) do
        Enum.at(centroids, cluster_id)
      else
        compute_centroid(cluster_vectors)
      end
    end)

    # Check convergence
    if centroids == new_centroids do
      new_centroids
    else
      iterate_kmeans(vectors, new_centroids, distance_fn, max_iterations, iteration + 1)
    end
  end

  defp find_nearest_centroid(vector, centroids, distance_fn) do
    centroids
    |> Enum.with_index()
    |> Enum.min_by(fn {centroid, _idx} -> distance(vector, centroid, distance_fn) end)
    |> elem(1)
  end

  defp compute_centroid(vectors) do
    dim = length(hd(vectors))
    count = length(vectors)

    vectors
    |> Enum.reduce(List.duplicate(0.0, dim), fn v, acc ->
      Enum.zip(v, acc) |> Enum.map(fn {a, b} -> a + b end)
    end)
    |> Enum.map(&(&1 / count))
  end

  defp distance(v1, v2, :cosine), do: 1.0 - similarity(v1, v2, :cosine)
  defp distance(v1, v2, :euclidean) do
    Enum.zip(v1, v2)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - b) * (a - b) end)
    |> :math.sqrt()
  end

  defp similarity(v1, v2, :cosine) do
    dot = Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    norm1 = :math.sqrt(Enum.reduce(v1, 0.0, fn x, acc -> acc + x * x end))
    norm2 = :math.sqrt(Enum.reduce(v2, 0.0, fn x, acc -> acc + x * x end))
    dot / (norm1 * norm2 + 1.0e-10)
  end
  defp similarity(v1, v2, :euclidean) do
    1.0 / (1.0 + distance(v1, v2, :euclidean))
  end

  defp search_buffer(query_embedding, opts, state) do
    limit = Keyword.get(opts, :limit, 20)

    results = state.training_buffer
    |> Enum.map(fn {doc, embedding} ->
      %{
        id: doc.id,
        similarity: similarity(query_embedding, embedding, state.distance_fn),
        metadata: doc.metadata,
        vector: embedding
      }
    end)
    |> Enum.sort_by(& &1.similarity, :desc)
    |> Enum.take(limit)

    {:ok, results}
  end
end

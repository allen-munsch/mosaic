defmodule Mosaic.Index.Strategy do
  @moduledoc """
  Behaviour for pluggable indexing strategies.
  
  Supported strategies:
  - :centroid - Centroid-based shard routing (default)
  - :quantized - Scalar quantization with hierarchical cells
  - :hnsw - Hierarchical Navigable Small World graphs
  - :binary - Binary embeddings with XOR + POPCNT
  - :ivf - Inverted File Index with clustering
  - :pq - Product Quantization for compressed vectors
  """

  @type vector :: [float()]
  @type binary_vector :: bitstring()
  @type document :: %{id: String.t(), text: String.t(), metadata: map()}
  @type search_opts :: keyword()
  @type candidate :: %{
    id: String.t(),
    similarity: float(),
    metadata: map()
  }

  @doc "Initialize the strategy with configuration options"
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Index a document with its embedding"
  @callback index_document(doc :: document(), embedding :: vector() | binary_vector(), state :: term()) :: 
    {:ok, term()} | {:error, term()}

  @doc "Index multiple documents in batch (optional, default iterates)"
  @callback index_batch(docs :: [{document(), vector() | binary_vector()}], state :: term()) ::
    {:ok, term()} | {:error, term()}

  @doc "Delete a document by ID"
  @callback delete_document(doc_id :: String.t(), state :: term()) :: :ok | {:error, term()}

  @doc "Find candidate documents for a query embedding"
  @callback find_candidates(query_embedding :: vector() | binary_vector(), opts :: search_opts(), state :: term()) :: 
    {:ok, [candidate()]} | {:error, term()}

  @doc "Get strategy statistics and health info"
  @callback get_stats(state :: term()) :: map()

  @doc "Serialize index state for persistence (optional)"
  @callback serialize(state :: term()) :: {:ok, binary()} | {:error, term()}

  @doc "Deserialize index state from persistence (optional)"
  @callback deserialize(data :: binary(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Optimize/compact the index (optional)"
  @callback optimize(state :: term()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks [index_batch: 2, serialize: 1, deserialize: 2, optimize: 1]

  @doc "Default batch indexing implementation"
  def default_index_batch(docs, state, index_fn) do
    Enum.reduce_while(docs, {:ok, state}, fn {doc, embedding}, {:ok, acc_state} ->
      case index_fn.(doc, embedding, acc_state) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        error -> {:halt, error}
      end
    end)
  end
end

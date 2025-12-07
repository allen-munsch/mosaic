defmodule Mosaic.Index.Strategy do
  @type vector :: [float()]
  @type document :: %{id: String.t(), text: String.t(), metadata: map()}
  @type search_opts :: keyword()
  
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback index_document(doc :: document(), embedding :: vector(), state :: term()) :: {:ok, term()} | {:error, term()}
  @callback delete_document(doc_id :: String.t(), state :: term()) :: :ok | {:error, term()}
  @callback find_candidates(query_embedding :: vector(), opts :: search_opts(), state :: term()) :: {:ok, [map()]}
  @callback get_stats(state :: term()) :: map()
end

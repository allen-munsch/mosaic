defmodule Mosaic.Index.Router do
  @type shard_info :: %{id: String.t(), path: String.t(), doc_count: integer(), query_count: integer(), centroid: binary(), centroid_norm: float()}
  @type shard_path :: String.t()
  @callback route_query(query_embedding :: [float()], opts :: keyword()) :: {:ok, [shard_info()]}
  @callback route_insert(embedding :: [float()]) :: {:ok, shard_path()}
  @callback rebalance(opts :: keyword()) :: :ok
end

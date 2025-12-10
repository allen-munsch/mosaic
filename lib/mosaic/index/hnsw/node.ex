defmodule Mosaic.Index.HNSW.Node do
  @moduledoc "Represents a node in the HNSW graph"
  
  defstruct [:id, :vector, :level, :neighbors, :metadata]
  
  @type t :: %__MODULE__{
    id: String.t(),
    vector: [float()],
    level: non_neg_integer(),
    neighbors: %{non_neg_integer() => [String.t()]},
    metadata: map()
  }
end

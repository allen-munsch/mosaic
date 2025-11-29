defmodule Mosaic.Ranking.Scorers.VectorSimilarity do
  @behaviour Mosaic.Ranking.Scorer

  @impl true
  def name, do: :vector_similarity

  @impl true
  def score(%{similarity: sim}, _context) when is_number(sim) do
    # Already normalized to [0, 1] from cosine similarity
    max(0.0, sim)
  end
  def score(_, _), do: 0.0

  @impl true
  def weight, do: 0.6
end

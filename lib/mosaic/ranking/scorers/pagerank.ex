defmodule Mosaic.Ranking.Scorers.PageRank do
  @behaviour Mosaic.Ranking.Scorer

  @max_pagerank 100.0  # Normalize against expected max

  @impl true
  def name, do: :pagerank

  @impl true
  def score(%{pagerank: pr}, _context) when is_number(pr) do
    # Normalize PageRank to [0, 1]
    min(1.0, pr / @max_pagerank)
  end
  def score(_, _), do: 0.0

  @impl true
  def weight, do: 0.2
end

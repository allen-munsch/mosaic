defmodule Mosaic.Ranking.Scorers.Freshness do
  @behaviour Mosaic.Ranking.Scorer

  @half_life_days 30  # Score decays by half every 30 days

  @impl true
  def name, do: :freshness

  @impl true
  def score(%{created_at: created_at}, _context) when not is_nil(created_at) do
    age_days = DateTime.diff(DateTime.utc_now(), created_at, :day)
    # Exponential decay
    :math.pow(0.5, age_days / @half_life_days)
  end
  def score(_, _), do: 0.5  # Neutral score if no date

  @impl true
  def weight, do: 0.1
end

defmodule Mosaic.Ranking.Scorers.TextMatch do
  @behaviour Mosaic.Ranking.Scorer

  @impl true
  def name, do: :text_match

  @impl true
  def score(%{text: text}, %{query_terms: terms}) when is_binary(text) and is_list(terms) do
    text_lower = String.downcase(text)
    matches = Enum.count(terms, &String.contains?(text_lower, String.downcase(&1)))
    matches / max(length(terms), 1)
  end
  def score(_, _), do: 0.0

  @impl true
  def weight, do: 0.1
end

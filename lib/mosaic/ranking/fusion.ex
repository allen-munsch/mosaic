defmodule Mosaic.Ranking.Fusion do
  @moduledoc """
  Strategies for combining multiple scores into a final ranking.
  """

  @type scored_doc :: %{scores: %{atom() => float()}, final_score: float()}
  @type weights :: %{atom() => float()}

  @doc "Weighted linear combination (default)"
  @spec weighted_sum([map()], weights()) :: [scored_doc()]
  def weighted_sum(documents, weights) do
    documents
    |> Enum.map(fn doc ->
      final_score =
        weights
        |> Enum.reduce(0.0, fn {scorer_name, weight}, acc ->
          score = Map.get(doc.scores, scorer_name, 0.0)
          acc + score * weight
        end)

      Map.put(doc, :final_score, final_score)
    end)
    |> Enum.sort_by(& &1.final_score, :desc)
  end

  @doc "Reciprocal Rank Fusion - good when score scales differ"
  @spec rrf([map()], integer()) :: [scored_doc()]
  def rrf(documents, k \\ 60) do
    scorer_names =
      documents
      |> Enum.flat_map(&Map.keys(&1.scores))
      |> Enum.uniq()

    # Get ranking for each scorer
    rankings =
      scorer_names
      |> Enum.map(fn scorer_name ->
        ranked =
          documents
          |> Enum.sort_by(fn doc -> Map.get(doc.scores, scorer_name, 0.0) end, :desc)
          |> Enum.with_index(1)
          |> Enum.map(fn {doc, rank} -> {doc.id, rank} end)
          |> Map.new()

        {scorer_name, ranked}
      end)
      |> Map.new()

    # Compute RRF score
    documents
    |> Enum.map(fn doc ->
      rrf_score =
        scorer_names
        |> Enum.reduce(0.0, fn scorer_name, acc ->
          rank = get_in(rankings, [scorer_name, doc.id]) || length(documents)
          acc + 1.0 / (k + rank)
        end)

      Map.put(doc, :final_score, rrf_score)
    end)
    |> Enum.sort_by(& &1.final_score, :desc)
  end

  @doc "Maximum score across all scorers"
  @spec max_score([map()]) :: [scored_doc()]
  def max_score(documents) do
    documents
    |> Enum.map(fn doc ->
      final = doc.scores |> Map.values() |> Enum.max(fn -> 0.0 end)
      Map.put(doc, :final_score, final)
    end)
    |> Enum.sort_by(& &1.final_score, :desc)
  end
end

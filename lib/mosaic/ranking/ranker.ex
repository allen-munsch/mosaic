defmodule Mosaic.Ranking.Ranker do
  @moduledoc """
  Orchestrates the ranking pipeline.
  Configurable scorers, weights, and fusion strategy.
  """

  alias Mosaic.Ranking.Fusion
  alias Mosaic.Ranking.Scorers

  @default_scorers [
    Scorers.VectorSimilarity,
    Scorers.PageRank,
    Scorers.Freshness,
    Scorers.TextMatch
  ]

  @default_fusion :weighted_sum

defstruct [
    scorers: @default_scorers,
    weights: nil, # nil = use scorer defaults
    fusion: @default_fusion,
    min_score: 0.0
  ]

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc "Rank documents using configured scorers and fusion strategy"
  def rank(documents, context, %__MODULE__{} = ranker) do
    weights = resolve_weights(ranker)

    documents
    |> apply_scorers(context, ranker.scorers)
    |> apply_fusion(ranker.fusion, weights)
    |> filter_by_min_score(ranker.min_score)
  end

  defp apply_scorers(documents, context, scorers) do
    Enum.map(documents, fn doc ->
      scores =
        scorers
        |> Enum.map(fn scorer ->
          {scorer.name(), scorer.score(doc, context)}
        end)
        |> Map.new()

      Map.put(doc, :scores, scores)
    end)
  end

  defp apply_fusion(documents, :weighted_sum, weights) do
    Fusion.weighted_sum(documents, weights)
  end

  defp apply_fusion(documents, :rrf, _weights) do
    Fusion.rrf(documents)
  end

  defp apply_fusion(documents, :max, _weights) do
    Fusion.max_score(documents)
  end

  defp apply_fusion(documents, fusion_fn, weights) when is_function(fusion_fn, 2) do
    fusion_fn.(documents, weights)
  end

  defp resolve_weights(%{weights: nil, scorers: scorers}) do
    scorers
    |> Enum.map(fn scorer -> {scorer.name(), scorer.weight()} end)
    |> Map.new()
  end

  defp resolve_weights(%{weights: weights}), do: weights

  defp filter_by_min_score(documents, min_score) do
    Enum.filter(documents, &(&1.final_score >= min_score))
  end
end

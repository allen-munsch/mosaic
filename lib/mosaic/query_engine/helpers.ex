defmodule Mosaic.QueryEngine.Helpers do
  @moduledoc """
  Helper functions for Mosaic.QueryEngine, primarily for data processing and formatting.
  """

  def build_cache_key(query_text, opts, ranker) do
    components = [
      query_text,
      Keyword.get(opts, :limit, 20),
      ranker.fusion,
      :erlang.phash2(ranker.weights)
    ]
    "query:#{:erlang.phash2(components)}"
  end

  def extract_terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/)
    |> Enum.filter(&(String.length(&1) > 2))
  end

  def distance_to_similarity(nil), do: 0.0
  def distance_to_similarity(d) when is_number(d), do: 1.0 / (1.0 + d)

  def safe_decode(nil), do: %{}
  def safe_decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  def parse_datetime(nil), do: nil
  def parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end

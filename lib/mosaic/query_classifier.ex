defmodule Mosaic.QueryClassifier do
  @analytics_patterns [
    ~r/\bGROUP\s+BY\b/i,
    ~r/\bHAVING\b/i,
    ~r/\bWINDOW\b/i,
    ~r/\bOVER\s*\(/i,
    ~r/\bWITH\s+\w+\s+AS\s*\(/i,
    ~r/\bJOIN\b/i,
    ~r/\bUNION\b/i,
    ~r/\bINTERSECT\b/i,
    ~r/\bEXCEPT\b/i
  ]

  @aggregate_functions ~r/\b(COUNT|SUM|AVG|MIN|MAX|STDDEV|VARIANCE)\s*\(/i

  @vector_patterns [
    ~r/\bSEMANTIC\b/i,
    ~r/\bVECTOR_SEARCH\b/i,
    ~r/\bSIMILAR\s+TO\b/i,
    ~r/\bvec_distance/i
  ]

  def classify(query, opts \\ []) do
    cond do
      opts[:force_engine] -> opts[:force_engine]
      has_vector_syntax?(query) and has_sql_filter?(query) -> :hybrid_search
      has_vector_syntax?(query) -> :vector_search
      needs_analytics_engine?(query) -> :analytics
      has_simple_aggregate?(query) -> :simple_sql
      true -> :simple_sql
    end
  end

  defp has_vector_syntax?(query), do: Enum.any?( @vector_patterns, &Regex.match?(&1, query))
  defp has_sql_filter?(query), do: Regex.match?(~r/\bWHERE\b/i, query)
  defp needs_analytics_engine?(query), do: has_complex_pattern?(query) or has_multiple_aggregates?(query)
  defp has_complex_pattern?(query), do: Enum.any?( @analytics_patterns, &Regex.match?(&1, query))
  defp has_multiple_aggregates?(query), do: length(Regex.scan( @aggregate_functions, query)) > 1
  defp has_simple_aggregate?(query), do: Regex.match?( @aggregate_functions, query) and not has_complex_pattern?(query)
end

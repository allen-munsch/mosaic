defmodule Mosaic.QueryRouter do
  require Logger

  def execute(query, params \\ [], opts \\ []) do
    classification = Mosaic.QueryClassifier.classify(query, opts)
    Logger.debug("Query classified as #{classification}: #{String.slice(query, 0, 100)}")

    case classification do
      :vector_search -> Mosaic.HybridQuery.search(query, opts)
      :hybrid_search -> execute_hybrid_search(query, params, opts)
      :simple_sql    -> Mosaic.FederatedQuery.execute(query, params)
      :analytics     -> Mosaic.DuckDBBridge.query(query, params)
    end
  end

  defp execute_hybrid_search(query, params, opts) do
    {vector_query, sql_filter} = parse_hybrid_query(query)
    Mosaic.HybridQuery.search(vector_query, Keyword.merge(opts, [where: sql_filter, params: params]))
  end

  defp parse_hybrid_query(query) do
    case Regex.run(~r/SEMANTIC\s+'([^']+)'\s+WHERE\s+(.+)/is, query) do
      [_, vector_query, sql_filter] -> {vector_query, sql_filter}
      nil -> {query, nil}
    end
  end
end



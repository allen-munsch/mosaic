defmodule Mosaic.Search do
  require Logger

  @doc """
  Performs a search for the given query text and options.

  This function orchestrates the search process by calling into the QueryEngine
  to retrieve raw results and then formats them for presentation.
  """
  def perform_search(query_text, opts \\ []) do
    Logger.info("Performing search for: '#{query_text}' with options: #{inspect(opts)}")

    query_engine = Keyword.get(opts, :query_engine, Mosaic.QueryEngine)
    clean_opts = Keyword.delete(opts, :query_engine)

    case query_engine.execute_query(query_text, clean_opts) do
      {:ok, results} ->
        # Here, we can add logic for formatting or presenting results
        # For now, just return them as is.
        results
      {:error, reason} ->
        Logger.error("Search failed for '#{query_text}': #{inspect(reason)}")
        []
    end
  end

  # Move result formatting/presentation related helper functions here from QueryEngine if any
  # For example:
  # defp format_result(result) do
  #   result
  # end
end

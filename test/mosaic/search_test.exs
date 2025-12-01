defmodule Mosaic.SearchTest do
  use ExUnit.Case, async: false
  alias Mosaic.Search

  setup {Mosaic.TestHelpers, :setup_integration_test}


  test "perform_search/2 returns results for a valid query" do
    results = Search.perform_search("Elixir")
    assert is_list(results)
    assert length(results) > 0
    assert results |> hd() |> Map.get(:text) =~ "Elixir"
  end

  test "perform_search/2 returns empty list for a query with no matches" do
    results = Search.perform_search("non_existent_term_xyz")
    assert results == []
  end

  test "perform_search/2 passes options to query engine" do
    results = Search.perform_search("Elixir", limit: 1)
    assert length(results) == 1
  end
end
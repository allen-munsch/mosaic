defmodule Mosaic.SearchTest do
  use ExUnit.Case, async: true

  describe "search/1" do
    test "returns list of results" do
      results = Mosaic.Search.search("test query")
      assert is_list(results)
    end

    test "results contain expected fields" do
      [result | _] = Mosaic.Search.search("test")
      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :text)
    end

    test "includes query in result text" do
      query = "unique_search_term"
      [result | _] = Mosaic.Search.search(query)
      assert result.text =~ query
    end
  end
end

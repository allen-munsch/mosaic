defmodule Mosaic.SearchTest do
  use ExUnit.Case, async: false # Changed to async: false because Mox expects synchronous setup for global defaults
  import Mox

  setup :verify_on_exit!

  test "perform_search/2 returns results for a valid query" do
    expect(Mosaic.QueryEngineMock, :execute_query, fn "test query", _opts ->
      {:ok, [%{id: 1, text: "Result from QueryEngine"}]}
    end)

    results = Mosaic.Search.perform_search("test query", query_engine: Mosaic.QueryEngineMock)
    assert results == [%{id: 1, text: "Result from QueryEngine"}]
  end

  test "perform_search/2 returns empty list on query engine error" do
    expect(Mosaic.QueryEngineMock, :execute_query, fn "error query", _opts ->
      {:error, :something_went_wrong}
    end)

    results = Mosaic.Search.perform_search("error query", query_engine: Mosaic.QueryEngineMock)
    assert results == []
  end

  test "perform_search/2 passes options to query engine" do
    opts_to_pass = [limit: 10, skip_cache: true]
    expect(Mosaic.QueryEngineMock, :execute_query, fn "query with opts", ^opts_to_pass ->
      {:ok, [%{id: 2, text: "Result with opts"}]}
    end)

    results = Mosaic.Search.perform_search("query with opts", Keyword.merge(opts_to_pass, query_engine: Mosaic.QueryEngineMock))
    assert results == [%{id: 2, text: "Result with opts"}]
  end
end
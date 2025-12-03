defmodule Mosaic.SearchTest do
  use ExUnit.Case, async: false
  import Mosaic.TestHelpers

  setup context do
    {:ok, setup_context} = Mosaic.TestHelpers.setup_integration_test(context)
    on_exit(setup_context.on_exit)
    {result, conn} = index_and_connect("search_doc", "Document about Elixir programming and Phoenix framework.")
    on_exit(fn -> cleanup_conn(result.shard_path, conn) end)
    {:ok, Map.merge(setup_context, %{shard: result})}
  end

  test "perform_search returns results for matching query" do
    results = Mosaic.Search.perform_search("Elixir", min_similarity: 0.01)
    assert length(results) > 0
    assert hd(results).text =~ "Elixir"
  end

  test "perform_search returns empty for non-matching query" do
    results = Mosaic.Search.perform_search("xyz_nonexistent_term_123", min_similarity: 0.9)
    assert results == []
  end

  test "perform_search respects limit option" do
    results = Mosaic.Search.perform_search("Elixir", limit: 1, min_similarity: 0.01)
    assert length(results) == 1
  end
end

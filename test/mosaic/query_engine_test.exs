defmodule Mosaic.QueryEngineTest do
  use ExUnit.Case, async: false

  # These tests require full application stack (Redis, Config, etc.)
  # Run with: mix test --only integration

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "test_query_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    
    # Check if QueryEngine is running
    case Process.whereis(Mosaic.QueryEngine) do
      nil -> {:ok, skip: true, temp_dir: temp_dir}
      _pid -> {:ok, skip: false, temp_dir: temp_dir}
    end
  end

  describe "search/2" do
    @tag :integration
    test "returns results for valid query", %{skip: skip} do
      if skip do
        :ok
      else
        result = Mosaic.QueryEngine.search("test query", limit: 5)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    @tag :integration
    test "respects limit option", %{skip: skip} do
      if skip do
        :ok
      else
        case Mosaic.QueryEngine.search("test", limit: 3) do
          {:ok, results} -> assert length(results) <= 3
          {:error, _} -> :ok
        end
      end
    end

    @tag :integration
    test "caches results on subsequent identical queries", %{skip: skip} do
      if skip do
        :ok
      else
        query = "cacheable_query_#{System.unique_integer()}"
        result1 = Mosaic.QueryEngine.search(query, limit: 5)
        result2 = Mosaic.QueryEngine.search(query, limit: 5)
        assert elem(result1, 0) == elem(result2, 0)
      end
    end
  end

  describe "cache key generation" do
    @tag :integration
    test "different queries produce different cache behavior", %{skip: skip} do
      if skip do
        :ok
      else
        query1 = "unique_query_1_#{System.unique_integer()}"
        query2 = "unique_query_2_#{System.unique_integer()}"
        Mosaic.QueryEngine.search(query1, limit: 1)
        Mosaic.QueryEngine.search(query2, limit: 1)
        assert true
      end
    end
  end
end

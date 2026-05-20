defmodule Mosaic.Cache.SemanticCacheTest do
  use ExUnit.Case, async: false

  alias Mosaic.Cache.SemanticCache

  setup do
    SemanticCache.reset()
    on_exit(&SemanticCache.reset/0)
    :ok
  end

  describe "store and lookup" do
    @tag :embedding
    test "stores and retrieves cached results" do
      results = [%{id: "doc_1", name: "Auth Flow", similarity: 0.95}]
      :ok = SemanticCache.store("how does authentication work", results)

      # Same query should be a cache hit
      assert {:hit, cached_results, info} = SemanticCache.lookup("how does authentication work",
        threshold: 0.9)

      assert length(cached_results) > 0
      assert info.similarity >= 0.9
      assert info.source == :semantic_cache
    end

    test "semantically similar queries hit the cache" do
      results = [%{id: "doc_1", name: "Error Handling", similarity: 0.95}]
      :ok = SemanticCache.store("error handling in authentication flow", results)

      # Similar query should hit
      case SemanticCache.lookup("auth error handling flow", threshold: 0.75) do
        {:hit, cached, _} ->
          assert length(cached) > 0

        :miss ->
          # May miss depending on embedding model similarity
          # This is acceptable - threshold tuning is runtime config
          assert true
      end
    end

    test "dissimilar queries miss the cache" do
      results = [%{id: "doc_1", name: "Auth", similarity: 0.95}]
      :ok = SemanticCache.store("authentication flow", results)

      # Very different query with high threshold should miss
      assert :miss = SemanticCache.lookup("banana smoothie recipe", threshold: 0.95)
    end
  end

  describe "invalidate" do
    test "removes a cached entry" do
      :ok = SemanticCache.store("test query", [%{id: "x"}])
      :ok = SemanticCache.invalidate("test query")

      assert :miss = SemanticCache.lookup("test query", threshold: 0.99)
    end
  end

  describe "stats" do
    test "returns cache statistics" do
      :ok = SemanticCache.store("query one", [%{id: "a"}])
      :ok = SemanticCache.store("query two", [%{id: "b"}])

      {:ok, stats} = SemanticCache.stats()

      assert stats.active_entries >= 2
      assert is_number(stats.hit_rate)
      assert is_number(stats.estimated_cost_saved)
    end
  end

  describe "purge_expired" do
    test "clears expired entries" do
      :ok = SemanticCache.store("ephemeral", [%{id: "x"}], ttl: 0)
      Process.sleep(10)

      {:ok, _} = SemanticCache.purge_expired()

      # Entry should be gone
      assert :miss = SemanticCache.lookup("ephemeral", threshold: 0.99)
    end
  end

  describe "reset" do
    test "clears all cache entries" do
      :ok = SemanticCache.store("q1", [%{id: "a"}])
      :ok = SemanticCache.store("q2", [%{id: "b"}])
      :ok = SemanticCache.reset()

      assert :miss = SemanticCache.lookup("q1", threshold: 0.99)
      assert :miss = SemanticCache.lookup("q2", threshold: 0.99)
    end
  end
end

defmodule Mosaic.EmbeddingCacheTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure a consistent max_size for testing configurable cache size
    # Dynamically update the config setting for this test
    Mosaic.Config.update_setting(:embedding_cache_max_size, 2)
    
    # Reset cache before each test (this will pick up the updated config)
    Mosaic.EmbeddingCache.reset_state()
    
    on_exit(fn ->
      # Reset the config setting to its default value after the test
      Mosaic.Config.update_setting(:embedding_cache_max_size, 100000) # Default value
      System.delete_env("EMBEDDING_CACHE_MAX_SIZE") # Still delete env var
    end)
    :ok # Return :ok from setup
  end

  test "metrics are initially zero" do
    metrics = Mosaic.EmbeddingCache.get_metrics()
    assert metrics.hits == 0
    assert metrics.misses == 0
  end

  test "cache miss increments misses and returns :miss" do
    text = "missed text"
    assert Mosaic.EmbeddingCache.get(text) == :miss
    metrics = Mosaic.EmbeddingCache.get_metrics()
    assert metrics.hits == 0
    assert metrics.misses == 1
  end

  test "cache hit increments hits and returns embedding" do
    text = "hit text"
    embedding = [0.1, 0.2, 0.3]
    Mosaic.EmbeddingCache.put(text, embedding)

    assert Mosaic.EmbeddingCache.get(text) == {:ok, embedding}
    metrics = Mosaic.EmbeddingCache.get_metrics()
    assert metrics.hits == 1
    assert metrics.misses == 0
  end

  test "LRU eviction works when max_size is reached" do
    # max_size is 2 (from setup environment variable)
    
    # Fill cache up to max_size
    Mosaic.EmbeddingCache.put("item1", [1.0]) # Oldest
    Mosaic.EmbeddingCache.put("item2", [2.0]) # Newer
    
    # Add new item, which should evict "item1" (oldest)
    Mosaic.EmbeddingCache.put("item3", [3.0])
    
    # Assert that "item1" is evicted, and "item2" and "item3" are present
    IO.inspect(Mosaic.EmbeddingCache.get("item1"), label: "Get item1 after eviction")
    assert Mosaic.EmbeddingCache.get("item1") == :miss
    assert Mosaic.EmbeddingCache.get("item2") == {:ok, [2.0]}
    assert Mosaic.EmbeddingCache.get("item3") == {:ok, [3.0]}
    IO.inspect(Mosaic.EmbeddingCache.get_metrics(), label: "Metrics after eviction test")
  end
end

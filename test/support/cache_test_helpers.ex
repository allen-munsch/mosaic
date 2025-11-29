defmodule Mosaic.CacheTestHelpers do
  defmacro define_cache_tests do
    quote do
      test "get/1 returns :miss for a nonexistent key", %{cache_module: cache, cache_name: name} do
        assert cache.get("nonexistent", name) == :miss
      end

      test "put/3 and get/1 work for a simple value", %{cache_module: cache, cache_name: name} do
        assert :ok = cache.put("key1", "value1", :infinity, name)
        assert {:ok, "value1"} = cache.get("key1", name)
      end

      test "put/3 and get/1 work for a map", %{cache_module: cache, cache_name: name} do
        payload = %{"a" => 1, "b" => [2, 3]}
        assert :ok = cache.put("key2", payload, :infinity, name)
        assert {:ok, ^payload} = cache.get("key2", name)
      end

      test "delete/1 removes a key", %{cache_module: cache, cache_name: name} do
        assert :ok = cache.put("key3", "value3", :infinity, name)
        assert {:ok, "value3"} = cache.get("key3", name)
        assert :ok = cache.delete("key3", name)
        assert :miss = cache.get("key3", name)
      end

      test "put/3 with a TTL expires the key", %{cache_module: cache, cache_name: name} do
        assert :ok = cache.put("ephemeral", "i will disappear", 1, name)
        assert {:ok, "i will disappear"} = cache.get("ephemeral", name)
        Process.sleep(1100)
        assert :miss = cache.get("ephemeral", name)
      end

      test "clear/0 removes all keys", %{cache_module: cache, cache_name: name} do
        assert :ok = cache.put("a", 1, :infinity, name)
        assert :ok = cache.put("b", 2, :infinity, name)
        assert {:ok, 1} = cache.get("a", name)
        assert {:ok, 2} = cache.get("b", name)
        assert :ok = cache.clear(name)
        assert :miss = cache.get("a", name)
        assert :miss = cache.get("b", name)
      end
    end
  end
end
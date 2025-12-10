defmodule Mosaic.CacheTestHelpers do
  defmacro define_cache_tests do
    quote do
      test "get returns :miss for non-existent key", %{cache_module: mod, cache_name: name} do
        assert mod.get("nonexistent_key", name) == :miss
      end

      test "put and get roundtrip", %{cache_module: mod, cache_name: name} do
        assert :ok = mod.put("key1", "value1", 300, name)
        assert {:ok, "value1"} = mod.get("key1", name)
      end

      test "delete removes key", %{cache_module: mod, cache_name: name} do
        mod.put("del_key", "val", 300, name)
        assert :ok = mod.delete("del_key", name)
        assert mod.get("del_key", name) == :miss
      end

      test "clear removes all keys", %{cache_module: mod, cache_name: name} do
        mod.put("c1", "v1", 300, name)
        mod.put("c2", "v2", 300, name)
        assert :ok = mod.clear(name)
        assert mod.get("c1", name) == :miss
        assert mod.get("c2", name) == :miss
      end
    end
  end
end

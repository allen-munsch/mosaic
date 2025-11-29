defmodule Mosaic.CacheTest do
  use ExUnit.Case, async: false
  import Mosaic.CacheTestHelpers

  # --- ETS Backend Tests ---
  describe "ETS Cache Backend" do
    setup do
      name = :"ets_cache_#{System.unique_integer([:positive])}"
      table = :"ets_table_#{System.unique_integer([:positive])}"
      start_opts = [name: name, table: table]

      {:ok, _pid} = Mosaic.Cache.ETS.start_link(start_opts)
      {:ok, cache_module: Mosaic.Cache.ETS, cache_name: name}
    end

    define_cache_tests()
  end

  # --- Redis Backend Tests ---
  describe "Redis Cache Backend" do
    setup do
      name = :"redis_cache_#{System.unique_integer([:positive])}"
      start_opts = [name: name, url: Mosaic.Config.get(:redis_url)]
      
      {:ok, _pid} = Mosaic.Cache.Redis.start_link(start_opts)
      
      # Clear the cache in Redis before the test runs
      Mosaic.Cache.Redis.clear(name)
      
      {:ok, cache_module: Mosaic.Cache.Redis, cache_name: name}
    end

    define_cache_tests()
  end
end

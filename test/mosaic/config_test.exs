defmodule Mosaic.ConfigTest do
  use ExUnit.Case

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "test_mosaic_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    {:ok, temp_dir: temp_dir}
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end

  test "returns default values when environment variables are not set", %{temp_dir: temp_dir} do
    env_vars = ["STORAGE_PATH", "EMBEDDING_MODEL", "ROUTING_DB_PATH", "CACHE_PATH", "EMBEDDING_DIM", "SHARD_SIZE", "MIN_SIMILARITY"]
    Enum.each(env_vars, &System.delete_env/1)

    System.put_env("STORAGE_PATH", Path.join(temp_dir, "shards"))
    System.put_env("ROUTING_DB_PATH", Path.join(temp_dir, "routing/index.db"))
    System.put_env("CACHE_PATH", Path.join(temp_dir, "cache"))

    {:ok, pid} = Mosaic.Config.start_link(name: nil)
    on_exit(fn -> stop_if_alive(pid) end)

    assert Mosaic.Config.get(:embedding_model, pid) == "local"
    assert Mosaic.Config.get(:embedding_dim, pid) == 384
    assert Mosaic.Config.get(:shard_size, pid) == 10000
    assert Mosaic.Config.get(:min_similarity, pid) == 0.1
  end

  test "overrides values with environment variables", %{temp_dir: temp_dir} do
    System.put_env("STORAGE_PATH", Path.join(temp_dir, "my_shards"))
    System.put_env("ROUTING_DB_PATH", Path.join(temp_dir, "my_routing/index.db"))
    System.put_env("CACHE_PATH", Path.join(temp_dir, "my_cache"))
    System.put_env("EMBEDDING_MODEL", "openai")
    System.put_env("EMBEDDING_DIM", "768")
    System.put_env("MIN_SIMILARITY", "0.5")

    {:ok, pid} = Mosaic.Config.start_link(name: nil)
    on_exit(fn -> stop_if_alive(pid) end)

    assert Mosaic.Config.get(:storage_path, pid) == Path.join(temp_dir, "my_shards")
    assert Mosaic.Config.get(:embedding_model, pid) == "openai"
    assert Mosaic.Config.get(:embedding_dim, pid) == 768
    assert Mosaic.Config.get(:min_similarity, pid) == 0.5
  end

  test "creates necessary directories", %{temp_dir: temp_dir} do
    test_storage = Path.join(temp_dir, "shards_dir")
    test_routing = Path.join(temp_dir, "routing_dir/index.db")
    test_cache = Path.join(temp_dir, "cache_dir")

    System.put_env("STORAGE_PATH", test_storage)
    System.put_env("ROUTING_DB_PATH", test_routing)
    System.put_env("CACHE_PATH", test_cache)

    {:ok, pid} = Mosaic.Config.start_link(name: nil)
    on_exit(fn -> stop_if_alive(pid) end)

    assert File.exists?(test_storage)
    assert File.exists?(Path.dirname(test_routing))
    assert File.exists?(test_cache)
  end
end

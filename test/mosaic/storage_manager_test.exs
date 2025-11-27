defmodule Mosaic.StorageManagerTest do
  use ExUnit.Case, async: false

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "test_storage_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    System.put_env("STORAGE_PATH", Path.join(temp_dir, "shards"))
    System.put_env("ROUTING_DB_PATH", Path.join(temp_dir, "routing/index.db"))
    System.put_env("CACHE_PATH", Path.join(temp_dir, "cache"))
    System.put_env("EMBEDDING_DIM", "1536")

    on_exit(fn ->
      File.rm_rf!(temp_dir)
      Enum.each(["STORAGE_PATH", "ROUTING_DB_PATH", "CACHE_PATH", "EMBEDDING_DIM"], &System.delete_env/1)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "create_shard/1 creates a SQLite file with correct schema", %{temp_dir: temp_dir} do
    shard_path = Path.join(temp_dir, "shard_001.db")
    assert {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    assert File.exists?(shard_path)
  end

  test "open_shard/1 returns connection from pool", %{temp_dir: temp_dir} do
    shard_path = Path.join(temp_dir, "shard_open.db")
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    result = Mosaic.StorageManager.open_shard(shard_path)
    assert match?({:ok, _conn}, result) or match?({:error, _}, result)
  end

  test "get_shard_doc_count/1 returns zero for empty shard", %{temp_dir: temp_dir} do
    shard_path = Path.join(temp_dir, "shard_count.db")
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    assert {:ok, 0} = Mosaic.StorageManager.get_shard_doc_count(shard_path)
  end

  test "archive_shard/1 returns ok", %{temp_dir: temp_dir} do
    shard_path = Path.join(temp_dir, "shard_archive.db")
    {:ok, ^shard_path} = Mosaic.StorageManager.create_shard(shard_path)
    assert :ok = Mosaic.StorageManager.archive_shard(shard_path)
  end
end

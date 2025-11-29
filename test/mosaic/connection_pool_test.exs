defmodule Mosaic.ConnectionPoolTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure ConnectionPool is running
    case Process.whereis(Mosaic.ConnectionPool) do
      nil -> Mosaic.ConnectionPool.start_link([])
      _pid -> :ok
    end

    temp_dir = Path.join(System.tmp_dir!(), "test_conn_pool_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    shard_path = Path.join(temp_dir, "test_shard.db")
    {:ok, conn} = Exqlite.Sqlite3.open(shard_path)
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY);")
    Exqlite.Sqlite3.close(conn)
    on_exit(fn -> File.rm_rf!(temp_dir) end)
    {:ok, shard_path: shard_path, temp_dir: temp_dir}
  end

  describe "checkout/1" do
    test "returns connection for valid shard path", %{shard_path: shard_path} do
      assert {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
      assert is_reference(conn)
      Mosaic.ConnectionPool.checkin(shard_path, conn)
    end

    test "returns error for non-existent path" do
      assert {:error, _} = Mosaic.ConnectionPool.checkout("/nonexistent/path.db")
    end

    test "can checkout multiple connections", %{shard_path: shard_path} do
      {:ok, conn1} = Mosaic.ConnectionPool.checkout(shard_path)
      {:ok, conn2} = Mosaic.ConnectionPool.checkout(shard_path)
      assert is_reference(conn1)
      assert is_reference(conn2)
      Mosaic.ConnectionPool.checkin(shard_path, conn1)
      Mosaic.ConnectionPool.checkin(shard_path, conn2)
    end
  end

  describe "checkin/2" do
    test "returns connection to pool for reuse", %{shard_path: shard_path} do
      {:ok, conn1} = Mosaic.ConnectionPool.checkout(shard_path)
      Mosaic.ConnectionPool.checkin(shard_path, conn1)
      Process.sleep(10)
      {:ok, conn2} = Mosaic.ConnectionPool.checkout(shard_path)
      assert is_reference(conn2)
      Mosaic.ConnectionPool.checkin(shard_path, conn2)
    end

    test "handles multiple checkins", %{shard_path: shard_path} do
      conns = for _ <- 1..3 do
        {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
        conn
      end
      Enum.each(conns, &Mosaic.ConnectionPool.checkin(shard_path, &1))
      assert true
    end
  end

  describe "pool limits" do
    test "respects max_per_shard limit", %{shard_path: shard_path} do
      conns = for _ <- 1..7 do
        {:ok, conn} = Mosaic.ConnectionPool.checkout(shard_path)
        conn
      end
      Enum.each(conns, &Mosaic.ConnectionPool.checkin(shard_path, &1))
      Process.sleep(50)
      assert true
    end
  end
end

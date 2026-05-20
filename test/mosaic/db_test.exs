defmodule Mosaic.DBTest do
  use ExUnit.Case, async: false

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "test_db_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    db_path = Path.join(temp_dir, "test.db")
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    Exqlite.Sqlite3.execute(conn, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, value INTEGER);")
    on_exit(fn ->
      Exqlite.Sqlite3.close(conn)
      File.rm_rf!(temp_dir)
    end)
    {:ok, conn: conn, db_path: db_path}
  end

  describe "execute/3" do
    test "inserts data successfully", %{conn: conn} do
      assert :ok = Mosaic.DB.execute(conn, "INSERT INTO items (name, value) VALUES (?, ?)", ["test", 42])
    end

    test "updates data successfully", %{conn: conn} do
      Mosaic.DB.execute(conn, "INSERT INTO items (name, value) VALUES (?, ?)", ["item1", 10])
      assert :ok = Mosaic.DB.execute(conn, "UPDATE items SET value = ? WHERE name = ?", [20, "item1"])
    end

    test "deletes data successfully", %{conn: conn} do
      Mosaic.DB.execute(conn, "INSERT INTO items (name, value) VALUES (?, ?)", ["to_delete", 1])
      assert :ok = Mosaic.DB.execute(conn, "DELETE FROM items WHERE name = ?", ["to_delete"])
    end

    test "handles empty params", %{conn: conn} do
      Mosaic.DB.execute(conn, "INSERT INTO items (name, value) VALUES (?, ?)", ["test", 1])
      assert :ok = Mosaic.DB.execute(conn, "DELETE FROM items", [])
    end
  end
end

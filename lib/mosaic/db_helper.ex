defmodule Mosaic.Test.DBHelpers do
  @moduledoc "Test helpers for raw SQLite queries using Exqlite.Sqlite3 API"

  @doc """
  Execute a query and return all rows.
  Use this instead of Exqlite.query() which expects DBConnection.

  ## Example
      {:ok, rows} = DBHelpers.query(conn, "SELECT * FROM shard_metadata")
  """
  def query(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    {:ok, rows}
  rescue
    e -> {:error, e}
  end

  defp fetch_all(conn, stmt, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end
end

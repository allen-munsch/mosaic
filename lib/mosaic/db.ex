defmodule Mosaic.DB do
  def execute(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    result = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    case result do
      :done -> :ok
      :ok -> :ok
      {:row, _} -> :ok
      other -> other
    end
  end
end

defmodule Mosaic.DBHelpers do
  defdelegate query(conn, sql, params \\ []), to: Mosaic.DB
  defdelegate execute(conn, sql, params \\ []), to: Mosaic.DB
  defdelegate query_one(conn, sql, params \\ []), to: Mosaic.DB
  defdelegate query_row(conn, sql, params \\ []), to: Mosaic.DB
end

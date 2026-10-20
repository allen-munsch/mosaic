defmodule Mosaic.DBHelpers do
  @spec query(reference(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  defdelegate query(conn, sql, params \\ []), to: Mosaic.DB

  @spec execute(reference(), String.t(), list()) :: :ok | term()
  defdelegate execute(conn, sql, params \\ []), to: Mosaic.DB

  @spec query_one(reference(), String.t(), list()) :: {:ok, term() | nil} | {:error, term()}
  defdelegate query_one(conn, sql, params \\ []), to: Mosaic.DB

  @spec query_row(reference(), String.t(), list()) :: {:ok, list() | nil} | {:error, term()}
  defdelegate query_row(conn, sql, params \\ []), to: Mosaic.DB
end

defmodule Mosaic.DB do
  @moduledoc "Low-level SQLite operations using raw Exqlite.Sqlite3 API"

  @type conn :: reference()
  @type row :: list()

  @spec execute(conn(), String.t(), list()) :: :ok | term()
  def execute(conn, sql, params \\ []) do
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

  @doc "Execute query and return all rows - replacement for Exqlite.query"
  @spec query(conn(), String.t(), list()) :: {:ok, [row()]} | {:error, term()}
  def query(conn, sql, params \\ []) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    rows = fetch_all_rows(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    {:ok, rows}
  rescue
    e -> {:error, e}
  end

  @doc "Execute query and return single scalar value"
  @spec query_one(conn(), String.t(), list()) :: {:ok, term() | nil} | {:error, term()}
  def query_one(conn, sql, params \\ []) do
    case query(conn, sql, params) do
      {:ok, [[val] | _]} -> {:ok, val}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  @doc "Execute query expecting single row"
  @spec query_row(conn(), String.t(), list()) :: {:ok, row() | nil} | {:error, term()}
  def query_row(conn, sql, params \\ []) do
    case query(conn, sql, params) do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      {:error, _} = err -> err
    end
  end
end

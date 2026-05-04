defmodule Mosaic.Migrations do
  @moduledoc """
  Versioned database migration system for MosaicDB.

  Ensures SQLite shard schemas are always at the correct version.
  Migrations are idempotent — running them multiple times is safe.
  """

  require Logger

  @type migration :: module()

  @callback up(conn :: reference()) :: :ok | {:error, term()}
  @callback down(conn :: reference()) :: :ok | {:error, term()}

  @migrations [
    Mosaic.Migrations.V1,
  ]

  @doc "Apply all pending migrations to a shard database."
  def apply(shard_path) do
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      ensure_version_table(conn)
      current = get_version(conn)

      to_apply = @migrations
      |> Enum.with_index(1)
      |> Enum.filter(fn {_mod, idx} -> idx > current end)

      results = Enum.map(to_apply, fn {mod, _idx} ->
        Logger.info("Applying migration: #{inspect(mod)} to #{shard_path}")
        case mod.up(conn) do
          :ok ->
            set_version(conn, mod)
            :ok

          {:error, reason} ->
            Logger.error("Migration #{inspect(mod)} failed: #{inspect(reason)}")
            {:error, reason}
        end
      end)

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :migration_failed}
    end)
  end

  @doc "Get the current migration version for a shard."
  def current_version(shard_path) do
    Mosaic.ConnectionPool.scoped_checkout(shard_path, fn conn ->
      ensure_version_table(conn)
      {:ok, get_version(conn)}
    end)
  end

  @doc "List all available migrations with their version numbers."
  def list_migrations do
    @migrations
    |> Enum.with_index(1)
    |> Enum.map(fn {mod, v} -> %{version: v, module: mod} end)
  end

  # ── Private ────────────────────────────────────────────────

  defp ensure_version_table(conn) do
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at TEXT DEFAULT (datetime('now'))
      );
    """)
  end

  defp get_version(conn) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [v]} ->
        Exqlite.Sqlite3.release(conn, stmt)
        if is_integer(v), do: v, else: String.to_integer(v)

      :done ->
        Exqlite.Sqlite3.release(conn, stmt)
        0
    end
  end

  defp set_version(conn, mod) do
    version = Enum.find_index(@migrations, &(&1 == mod)) + 1
    name = mod |> Module.split() |> List.last()

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO schema_migrations (version, name) VALUES (?, ?)")
    :ok = Exqlite.Sqlite3.bind(stmt, [version, name])
    Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end
end

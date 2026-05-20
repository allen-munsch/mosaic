defmodule Mosaic.Tenancy.Isolator do
  @moduledoc """
  Multi-tenant isolation layer for MosaicDB.

  Routes all operations through tenant-scoped storage paths, ensuring
  data isolation between tenants. Works with the auth layer to enforce
  per-tenant access controls.

  ## Architecture

      /shards/
      ├── tenant_abc123/          # Tenant A
      │   ├── codebase_001.db
      │   ├── docs_2024.db
      │   └── handles.db
      ├── tenant_def456/          # Tenant B
      │   ├── knowledge_base.db
      │   └── handles.db
      └── _system/                # Internal (auth, billing, config)
          ├── auth.db
          └── system.db

  ## Usage

      # Get tenant storage path
      path = Mosaic.Tenancy.Isolator.storage_path("tenant_abc")

      # Scoped to tenant
      {:ok, shards} = Mosaic.Tenancy.Isolator.list_shards("tenant_abc")

      # Create a new tenant
      Mosaic.Tenancy.Isolator.create_tenant("tenant_new", "My Tenant")
  """

  @system_tenant "_system"

  @doc "Get the storage path for a specific tenant."
  def storage_path(tenant_id) when is_binary(tenant_id) do
    base = Mosaic.Config.get(:storage_path)
    Path.join(base, sanitize_tenant_id(tenant_id))
  end

  @doc "Get the system storage path."
  def system_path do
    storage_path(@system_tenant)
  end

  @doc "List all shard files for a tenant."
  def list_shards(tenant_id) when is_binary(tenant_id) do
    path = storage_path(tenant_id)
    with true <- File.dir?(path) do
      Path.wildcard(Path.join(path, "*.db"))
      |> Enum.filter(fn f -> not String.contains?(f, "wal") and not String.contains?(f, "shm") end)
      |> then(&{:ok, &1})
    else
      false -> {:ok, []}
    end
  end

  @doc "Create a new tenant with storage allocation."
  def create_tenant(tenant_id, name, opts \\ []) when is_binary(tenant_id) do
    quota = Keyword.get(opts, :quota_bytes, 10_737_418_240) # 10 GB default
    path = storage_path(tenant_id)
    File.mkdir_p!(path)

    with {:ok, conn} <- get_system_conn() do
      Mosaic.DB.execute(conn, """
        INSERT OR REPLACE INTO tenants (tenant_id, name, storage_path, quota_bytes)
        VALUES (?, ?, ?, ?)
      """, [tenant_id, name, path, quota])
      release_conn(conn)
      {:ok, %{tenant_id: tenant_id, name: name, storage_path: path, quota_bytes: quota}}
    end
  end

  @doc "Delete a tenant and all their data."
  def delete_tenant(tenant_id) when is_binary(tenant_id) do
    if tenant_id == @system_tenant do
      {:error, :cannot_delete_system_tenant}
    else
      path = storage_path(tenant_id)

      with {:ok, conn} <- get_system_conn() do
        Mosaic.DB.execute(conn, "DELETE FROM tenants WHERE tenant_id = ?", [tenant_id])
        # Also delete api_keys
        Mosaic.DB.execute(conn, "DELETE FROM api_keys WHERE tenant_id = ?", [tenant_id])
        release_conn(conn)
      end

      if File.dir?(path) do
        File.rm_rf!(path)
      end

      :ok
    end
  end

  @doc "Get tenant info from the system database."
  def get_tenant(tenant_id) when is_binary(tenant_id) do
    with {:ok, conn} <- get_system_conn() do
      result = Mosaic.DB.query(conn,
        "SELECT tenant_id, name, storage_path, quota_bytes, active FROM tenants WHERE tenant_id = ?",
        [tenant_id])
      release_conn(conn)

      case result do
        {:ok, [[tid, name, storage_path, quota, active] | _]} ->
          {:ok, %{
            tenant_id: tid,
            name: name,
            storage_path: storage_path,
            quota_bytes: quota,
            active: active == 1
          }}

        {:ok, []} ->
          {:error, :not_found}

        err -> err
      end
    end
  end

  @doc "Get storage usage for a tenant in bytes."
  def storage_usage(tenant_id) when is_binary(tenant_id) do
    path = storage_path(tenant_id)

    if File.dir?(path) do
      size = path
      |> Path.join("*.db")
      |> Path.wildcard()
      |> Enum.map(&File.stat!(&1).size)
      |> Enum.sum()
      {:ok, size}
    else
      {:ok, 0}
    end
  end

  @doc "Check if a tenant has exceeded their quota."
  def quota_exceeded?(tenant_id) when is_binary(tenant_id) do
    with {:ok, tenant} <- get_tenant(tenant_id),
         {:ok, usage} <- storage_usage(tenant_id) do
      usage >= tenant.quota_bytes
    else
      _ -> false
    end
  end

  @doc "List all active tenants."
  def list_tenants do
    with {:ok, conn} <- get_system_conn() do
      result = Mosaic.DB.query(conn,
        "SELECT tenant_id, name, storage_path, quota_bytes, active FROM tenants WHERE active = 1")
      release_conn(conn)

      case result do
        {:ok, rows} ->
          tenants = Enum.map(rows, fn [tid, name, path, quota, active] ->
            %{tenant_id: tid, name: name, storage_path: path, quota_bytes: quota, active: active == 1}
          end)
          {:ok, tenants}

        err -> err
      end
    end
  end

  @doc "Initialize the system tenant storage (auth db, system db)."
  def init_system do
    Mosaic.Auth.APIKey.init_auth_db()
    system_path() |> File.mkdir_p!()

    with {:ok, conn} <- get_system_conn() do
      Mosaic.DB.execute(conn, """
        CREATE TABLE IF NOT EXISTS tenants (
          tenant_id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          storage_path TEXT,
          quota_bytes INTEGER DEFAULT 10737418240,
          created_at TEXT DEFAULT (datetime('now')),
          active INTEGER DEFAULT 1
        );
      """)

      Mosaic.DB.execute(conn, """
        CREATE TABLE IF NOT EXISTS usage_log (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tenant_id TEXT NOT NULL,
          operation TEXT NOT NULL,
          bytes_processed INTEGER DEFAULT 0,
          duration_ms INTEGER DEFAULT 0,
          timestamp TEXT DEFAULT (datetime('now'))
        );
      """)

      Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_usage_tenant ON usage_log(tenant_id, timestamp);")

      release_conn(conn)
      :ok
    end
  end

  @doc "Log an operation for billing/usage tracking."
  def log_usage(tenant_id, operation, bytes_processed \\ 0, duration_ms \\ 0) do
    with {:ok, conn} <- get_system_conn() do
      Mosaic.DB.execute(conn,
        "INSERT INTO usage_log (tenant_id, operation, bytes_processed, duration_ms) VALUES (?, ?, ?, ?)",
        [tenant_id, operation, bytes_processed, duration_ms])
      release_conn(conn)
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp sanitize_tenant_id(id) do
    String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")
  end

  defp get_system_conn do
    db_path = Path.join(system_path(), "system.db")
    File.mkdir_p!(Path.dirname(db_path))
    unless File.exists?(db_path), do: File.write!(db_path, "")
    # Use Exqlite directly to avoid vec extension dependency
    Exqlite.Sqlite3.open(db_path)
  end

  defp release_conn(conn) do
    Exqlite.Sqlite3.close(conn)
  end
end

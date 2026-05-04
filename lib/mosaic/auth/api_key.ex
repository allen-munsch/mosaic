defmodule Mosaic.Auth.APIKey do
  @moduledoc """
  API key management for MosaicDB.

  Supports creation, validation, revocation, and scope-based permissions.
  Keys are stored in a dedicated SQLite auth database with bcrypt hashing.

  ## Usage

      # Create a new API key
      {:ok, key, key_id} = Mosaic.Auth.APIKey.create_key("tenant_abc", ["read", "write"])

      # Validate an API key
      {:ok, claims} = Mosaic.Auth.APIKey.validate_key("mk_live_abc123...")

      # Revoke a key
      :ok = Mosaic.Auth.APIKey.revoke_key("key_id_123")
  """

  @key_prefix "mk_live_"
  @key_id_prefix "mkid_"

  @doc "Create a new API key for a tenant with specified scopes."
  def create_key(tenant_id, scopes, opts \\ []) when is_binary(tenant_id) and is_list(scopes) do
    key_id = "#{@key_id_prefix}#{generate_id()}"
    raw_key = generate_raw_key()
    key_hash = Bcrypt.hash_pwd_salt(raw_key)
    label = Keyword.get(opts, :label, "API Key #{String.slice(key_id, -6, 6)}")
    ttl = Keyword.get(opts, :ttl, :infinity)

    with {:ok, conn} <- get_auth_conn() do
      Mosaic.DB.execute(conn, """
        INSERT INTO api_keys (key_id, key_hash, tenant_id, scopes, label, ttl_seconds, created_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
      """, [key_id, key_hash, tenant_id, Jason.encode!(scopes), label, encode_ttl(ttl)])

      release_conn(conn)
    end

    full_key = "#{@key_prefix}#{key_id}_#{raw_key}"
    {:ok, full_key, key_id}
  end

  @doc "Validate an API key (format: mk_live_KEYID_RAWKEY)."
  def validate_key(key) when is_binary(key) do
    with {:ok, key_id, raw} <- parse_key(key),
         {:ok, conn} <- get_auth_conn(),
         {:ok, [[hash, tenant_id, scopes_json | _]]} <-
           Mosaic.DB.query(conn,
             "SELECT key_hash, tenant_id, scopes FROM api_keys WHERE key_id = ? AND revoked_at IS NULL",
             [key_id]) do

      release_conn(conn)

      if Bcrypt.verify_pass(raw, hash) do
        scopes = Jason.decode!(scopes_json)
        {:ok, %{tenant_id: tenant_id, scopes: scopes, key_id: key_id}}
      else
        {:error, :invalid_key}
      end
    else
      {:ok, []} -> {:error, :unknown_key}
      {:error, :invalid_format} -> {:error, :invalid_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Revoke an API key by its key_id."
  def revoke_key(key_id) when is_binary(key_id) do
    with {:ok, conn} <- get_auth_conn() do
      Mosaic.DB.execute(conn,
        "UPDATE api_keys SET revoked_at = datetime('now') WHERE key_id = ?",
        [key_id])
      release_conn(conn)
      :ok
    end
  end

  @doc "List active keys for a tenant."
  def list_keys(tenant_id) when is_binary(tenant_id) do
    with {:ok, conn} <- get_auth_conn() do
      result = Mosaic.DB.query(conn,
        "SELECT key_id, scopes, label, created_at FROM api_keys " <>
        "WHERE tenant_id = ? AND revoked_at IS NULL ORDER BY created_at DESC",
        [tenant_id])
      release_conn(conn)

      case result do
        {:ok, rows} ->
          keys = Enum.map(rows, fn [key_id, scopes_json, label, created_at] ->
            %{
              key_id: key_id,
              scopes: Jason.decode!(scopes_json),
              label: label,
              created_at: created_at
            }
          end)
          {:ok, keys}

        err -> err
      end
    end
  end

  @doc "Initialize the auth database."
  def init_auth_db do
    db_path = auth_db_path()
    File.mkdir_p!(Path.dirname(db_path))

    unless File.exists?(db_path) do
      File.write!(db_path, "")
    end

    with {:ok, conn} <- Mosaic.ConnectionPool.checkout(db_path) do
      Mosaic.DB.execute(conn, """
        CREATE TABLE IF NOT EXISTS api_keys (
          key_id TEXT PRIMARY KEY,
          key_hash TEXT NOT NULL,
          tenant_id TEXT NOT NULL,
          scopes TEXT NOT NULL DEFAULT '["read"]',
          label TEXT,
          ttl_seconds INTEGER,
          created_at TEXT DEFAULT (datetime('now')),
          revoked_at TEXT
        );
      """)

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

      Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_api_keys_tenant ON api_keys(tenant_id);")
      Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_api_keys_revoked ON api_keys(revoked_at);")

      Mosaic.ConnectionPool.checkin(db_path, conn)
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp parse_key(key) do
    case String.starts_with?(key, @key_prefix) do
      true ->
        rest = String.replace_prefix(key, @key_prefix, "")
        parts = String.split(rest, "_", parts: 2)
        if length(parts) == 2 do
          [key_id, raw] = parts
          {:ok, "#{@key_id_prefix}#{key_id}", raw}
        else
          {:error, :invalid_format}
        end

      false ->
        {:error, :invalid_format}
    end
  end

  defp generate_raw_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp encode_ttl(:infinity), do: nil
  defp encode_ttl(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp auth_db_path do
    Mosaic.Config.get(:auth_db_path, Path.join(Mosaic.Config.get(:storage_path), "auth.db"))
  end

  defp get_auth_conn do
    init_auth_db()
    Mosaic.ConnectionPool.checkout(auth_db_path())
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(auth_db_path(), conn)
  end
end

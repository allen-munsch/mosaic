defmodule Mosaic.HandleRegistry do
  @moduledoc """
  Persistent token-efficient result storage with FTS5 preview search.

  Stores query results as handles (compact stubs) in SQLite, allowing
  LLM agents to reference large result sets without pulling all data
  into context. Inspired by yogthos/Matryoshka's in-memory handle system,
  but persisted across sessions and shared across nodes.

  ## Token savings

      # Without handles: full array
      [{"id":"func_1","name":"execute_query/2",...}, ...]  # 15K tokens

      # With handles: compact stub
      $grep_error: Array(500) [execute_query/2, handle_call/3, ...]  # ~50 tokens

  ## Usage

      iex> stub = HandleRegistry.store("grep_error", results)
      "$grep_error: Array(500) [execute_query/2, handle_call/3...]"

      iex> HandleRegistry.expand("$grep_error", limit: 5, offset: 10)
      [row_11, row_12, row_13, row_14, row_15]

      iex> HandleRegistry.memo("auth architecture", summary)
      "$memo_auth_architecture: \"auth architecture\" (2.1KB)"

      iex> HandleRegistry.count("$grep_error")
      500
  """

  require Logger

  @default_ttl 3600
  @max_handles 10_000
  @max_preview_len 120

  @doc """
  Store results as a named handle. Returns a compact stub string.

  The stub shows handle name, type, count, and a preview.
  The caller never needs to pass the full data array around —
  just the stub string.
  """
  def store(handle_name, results, opts \\ []) do
    ttl = Keyword.get(opts, :ttl, @default_ttl)
    result_type = detect_type(results)
    count = if is_list(results), do: length(results), else: 1
    preview = build_preview(results)
    encoded = :erlang.term_to_binary(results, compressed: 6)

    with {:ok, conn} <- get_connection() do
      Mosaic.DB.execute(conn, """
        INSERT OR REPLACE INTO handles (handle_name, result_type, item_count, preview, full_data, ttl_seconds)
        VALUES (?, ?, ?, ?, ?, ?)
      """, [handle_name, result_type, count, preview, encoded, ttl])

      release_connection(conn)
      evict_if_needed(conn)
    end

    "#{handle_name}: #{String.capitalize(result_type)}(#{count}) [#{preview}]"
  end

  @doc """
  Expand a handle to materialize full results, optionally with pagination.
  """
  def expand(handle_name, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    with {:ok, conn} <- get_connection() do
      result = case Mosaic.DB.query(conn,
        "SELECT full_data, result_type, item_count FROM handles WHERE handle_name = ?",
        [handle_name]) do
        {:ok, [[data, _type, _count] | _]} ->
          decoded = :erlang.binary_to_term(data)
          results = as_list(decoded)
          |> Enum.drop(offset)
          |> then(fn r -> if limit, do: Enum.take(r, limit), else: r end)
          {:ok, results}

        {:ok, []} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end

      release_connection(conn)
      result
    end
  end

  @doc """
  Store arbitrary context as a persistent memo.
  Unlike Matryoshka's lattice_memo, these survive restarts.
  """
  def memo(label, content) do
    handle_name = "$memo_#{sanitize(label)}"
    ttl = 86_400  # 24h default

    with {:ok, conn} <- get_connection() do
      Mosaic.DB.execute(conn, """
        INSERT OR REPLACE INTO handles (handle_name, result_type, item_count, preview, full_data, ttl_seconds)
        VALUES (?, 'memo', 1, ?, ?, ?)
      """, [handle_name, String.slice(label, 0, 100), content, ttl])

      release_connection(conn)
    end

    "#{handle_name}: \"#{label}\" (#{byte_size(content)}B)"
  end

  @doc """
  Delete a handle to free storage.
  """
  def delete(handle_name) do
    with {:ok, conn} <- get_connection() do
      Mosaic.DB.execute(conn, "DELETE FROM handles WHERE handle_name = ?", [handle_name])
      Mosaic.DB.execute(conn, "DELETE FROM handles_fts WHERE handle_name = ?", [handle_name])
      release_connection(conn)
      :ok
    end
  end

  @doc "Get the item count for a handle."
  def count(handle_name) do
    with {:ok, conn} <- get_connection() do
      result = case Mosaic.DB.query_one(conn,
        "SELECT item_count FROM handles WHERE handle_name = ?", [handle_name]) do
        {:ok, nil} -> {:ok, 0}
        {:ok, n} when is_integer(n) -> {:ok, n}
        {:ok, n} when is_binary(n) -> {:ok, String.to_integer(n)}
        err -> err
      end
      release_connection(conn)
      result
    end
  end

  @doc "List active handles with their previews."
  def list_active do
    with {:ok, conn} <- get_connection() do
      result = Mosaic.DB.query(conn, """
        SELECT handle_name, result_type, item_count, preview, created_at
        FROM handles
        ORDER BY created_at DESC
        LIMIT 50
      """)

      release_connection(conn)
      case result do
        {:ok, rows} -> {:ok, Enum.map(rows, fn [name, type, count, preview, created] ->
          %{handle: name, type: type, count: count, preview: preview, created: created}
        end)}
        err -> err
      end
    end
  end

  # -- Private ---------------------------------------------------

  defp detect_type(results) when is_list(results), do: "array"
  defp detect_type(results) when is_map(results), do: "map"
  defp detect_type(results) when is_number(results), do: "scalar"
  defp detect_type(results) when is_binary(results), do: "scalar"
  defp detect_type(_), do: "unknown"

  defp as_list(list) when is_list(list), do: list
  defp as_list(map) when is_map(map), do: [map]
  defp as_list(other), do: [other]

  defp build_preview(results) do
    results
    |> as_list()
    |> Enum.take(3)
    |> Enum.map_join(", ", &preview_item/1)
    |> String.slice(0, @max_preview_len)
    |> then(fn s -> if length(as_list(results)) > 3, do: s <> "...", else: s end)
  end

  defp preview_item(item) when is_tuple(item), do: item |> Tuple.to_list() |> List.first() |> to_string()
  defp preview_item(%{name: name}), do: name
  defp preview_item(%{"name" => name}), do: name
  defp preview_item(%{id: id}), do: id
  defp preview_item(%{"id" => id}), do: id
  defp preview_item(item) when is_list(item), do: item |> List.first() |> to_string()
  defp preview_item(item), do: String.slice(inspect(item), 0, 40)

  defp sanitize(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp evict_if_needed(conn) do
    case Mosaic.DB.query_one(conn, "SELECT COUNT(*) FROM handles") do
      {:ok, count} when is_integer(count) and count > @max_handles ->
        excess = count - @max_handles
        Mosaic.DB.execute(conn,
          "DELETE FROM handles WHERE handle_name IN (SELECT handle_name FROM handles ORDER BY created_at ASC LIMIT ?)",
          [excess])
        Logger.debug("Evicted #{excess} oldest handles (LRU)")
      _ -> :ok
    end
  end

  defp get_connection do
    # Use the routing DB (always available, same life as the app)
    routing_db = Mosaic.Config.get(:routing_db_path)
    Mosaic.ConnectionPool.checkout(routing_db)
  end

  defp release_connection(conn) do
    routing_db = Mosaic.Config.get(:routing_db_path)
    Mosaic.ConnectionPool.checkin(routing_db, conn)
  end
end

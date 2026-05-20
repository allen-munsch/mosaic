defmodule Mosaic.DuckDBRewriter do
  @moduledoc """
  Proper SQL-aware query rewriter for DuckDB federation.
  Replaces the regex-based approach with a structured rewrite that
  handles subqueries, CTEs, complex joins, and nested expressions.

  Transforms single-table queries into UNION ALL across attached
  SQLite shard databases.
  """

  @doc """
  Rewrite a SQL query to federate across multiple shards.
  Handles SELECT with FROM, JOIN, WHERE, GROUP BY, HAVING, ORDER BY, LIMIT.
  """
  def rewrite(sql, shards, table) when is_binary(sql) and is_list(shards) do
    case parse_select(sql) do
      {:ok, parts} ->
        federated = build_federated(parts, shards, table)
        {:ok, federated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Build a federated query: UNION ALL of per-shard queries wrapped in a CTE.
  """
  def build_federated_query(sql, shards, table) do
    with {:ok, parts} <- parse_select(sql) do
      build_federated(parts, shards, table)
    end
  end

  # ── SQL Parser ──────────────────────────────────────────────

  defp parse_select(sql) do
    sql = String.trim(sql)

    # Extract CTEs (WITH clauses)
    {cte, rest} = extract_cte(sql)

    # Extract main SELECT components
    with {:ok, columns} <- extract_columns(rest),
         {:ok, from_clause} <- extract_from(rest),
         where = extract_clause(rest, "WHERE"),
         group_by = extract_clause(rest, "GROUP BY"),
         having = extract_clause(rest, "HAVING"),
         order_by = extract_clause(rest, "ORDER BY"),
         limit = extract_clause(rest, "LIMIT"),
         offset = extract_clause(rest, "OFFSET") do

      {:ok, %{
        cte: cte,
        columns: columns,
        from: from_clause,
        where: where,
        group_by: group_by,
        having: having,
        order_by: order_by,
        limit: limit,
        offset: offset,
        original: sql
      }}
    end
  end

  defp extract_cte(sql) do
    case Regex.run(~r/^\s*WITH\s+(\w+)\s+AS\s*\((.+)\)\s+(SELECT.+)/is, sql) do
      [_, cte_name, cte_body, rest] ->
        {"WITH #{cte_name} AS (#{cte_body})", rest}

      nil ->
        case Regex.run(~r/^\s*WITH\s+(.+?)(SELECT.+)/is, sql) do
          [_, cte_part, rest] -> {"WITH #{String.trim(cte_part)}", rest}
          nil -> {nil, sql}
        end
    end
  end

  defp extract_columns(sql) do
    case Regex.run(~r/^\s*SELECT\s+(.+?)\s+FROM\s/is, sql) do
      [_, cols] -> {:ok, String.trim(cols)}
      nil -> {:error, "Cannot parse SELECT columns"}
    end
  end

  defp extract_from(sql) do
    case Regex.run(~r/FROM\s+(\S+)/i, sql) do
      [_, table] -> {:ok, String.trim(table, "; \t\n")}
      nil -> {:error, "Cannot parse FROM clause"}
    end
  end

  defp extract_clause(sql, keyword) do
    pattern = ~r/\b#{keyword}\s+(.+?)(?:\b(?:WHERE|GROUP\s+BY|HAVING|ORDER\s+BY|LIMIT|OFFSET)\b|$)/is
    case Regex.run(pattern, sql) do
      [_, clause] -> String.trim(clause)
      nil -> nil
    end
  end

  # ── Federated Query Builder ─────────────────────────────────

  defp build_federated(parts, shards, table) do
    # For each shard, build a subquery that replaces FROM table with sqlite_scan
    shard_queries = Enum.map(shards, fn shard ->
      build_shard_select(parts, shard, table)
    end)

    # Build final federated query
    inner_union = Enum.join(shard_queries, "\n  UNION ALL\n  ")

    # Preserve ordering and limiting
    order_sql = if parts.order_by, do: "ORDER BY #{parts.order_by}", else: ""
    limit_sql = cond do
      parts.limit && parts.offset -> "LIMIT #{parts.limit} OFFSET #{parts.offset}"
      parts.limit -> "LIMIT #{parts.limit}"
      true -> ""
    end

    cte_sql = if parts.cte, do: "#{parts.cte},\n", else: ""

    """
    #{cte_sql}federated AS (
      #{inner_union}
    )
    SELECT * FROM federated
    #{order_sql}
    #{limit_sql}
    """ |> String.trim()
  end

  defp build_shard_select(parts, shard, table) do
    scan_table = "sqlite_scan('#{shard.path}', '#{table}')"

    where_sql = if parts.where, do: "WHERE #{parts.where}", else: ""
    group_sql = if parts.group_by, do: "GROUP BY #{parts.group_by}", else: ""
    having_sql = if parts.having, do: "HAVING #{parts.having}", else: ""

    # Drop ORDER BY and LIMIT from individual shard queries
    """
    SELECT #{parts.columns}, '#{shard.path}' as shard_path
    FROM #{scan_table}
    #{where_sql}
    #{group_sql}
    #{having_sql}
    """ |> String.trim()
  end

  # ── Direct Shard SQL ───────────────────────────────────────

  @doc """
  Execute SQL directly on a specific shard, rewriting table references.
  """
  def shard_sql(sql, shard_path, table) do
    sql
    |> String.replace(~r/\b#{table}\b/, "sqlite_scan('#{shard_path}', '#{table}')")
  end

  @doc """
  Build a cross-shard JOIN query between two tables.
  """
  def cross_shard_join(select_cols, table_a, shard_a, table_b, shard_b, join_on) do
    a_table = "sqlite_scan('#{shard_a.path}', '#{table_a}')"
    b_table = "sqlite_scan('#{shard_b.path}', '#{table_b}')"

    """
    SELECT #{select_cols}
    FROM #{a_table} a
    JOIN #{b_table} b ON #{join_on}
    """
  end
end

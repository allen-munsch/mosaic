defmodule Mosaic.DuckDBRewriterTest do
  use ExUnit.Case

  alias Mosaic.DuckDBRewriter

  @shards [
    %{path: "/shards/shard_0.db"},
    %{path: "/shards/shard_1.db"},
    %{path: "/shards/shard_2.db"}
  ]

  describe "extract columns" do
    test "extracts SELECT columns" do
      result = DuckDBRewriter.rewrite(
        "SELECT id, name FROM documents",
        @shards,
        "documents"
      )
      assert {:ok, sql} = result
      assert String.contains?(sql, "sqlite_scan")
      assert String.contains?(sql, "UNION ALL")
    end

    test "extracts columns with wildcard" do
      result = DuckDBRewriter.rewrite(
        "SELECT * FROM documents",
        @shards,
        "documents"
      )
      assert {:ok, sql} = result
      assert String.contains?(sql, "SELECT *")
    end
  end

  describe "federated query building" do
    test "builds union all across shards" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT id FROM documents",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "UNION ALL")
      for shard <- @shards do
        assert String.contains?(sql, shard.path)
      end
    end

    test "preserves WHERE clause" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT id, name FROM documents WHERE category = 'books'",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "category = 'books'")
    end

    test "preserves GROUP BY clause" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT category, COUNT(*) FROM documents GROUP BY category",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "GROUP BY category")
    end

    test "preserves ORDER BY and LIMIT at federated level" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT id FROM documents ORDER BY id LIMIT 10",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "ORDER BY id")
      assert String.contains?(sql, "LIMIT 10")
    end

    test "handles HAVING clause" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT category, COUNT(*) as cnt FROM documents GROUP BY category HAVING cnt > 5",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "HAVING cnt > 5")
    end

    test "handles LIMIT with OFFSET" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT id FROM documents LIMIT 10 OFFSET 20",
        @shards,
        "documents"
      )

      assert String.contains?(sql, "OFFSET 20")
    end
  end

  describe "edge cases" do
    test "handles empty shard list" do
      result = DuckDBRewriter.rewrite("SELECT id FROM documents", [], "documents")
      assert {:ok, sql} = result
      # Should still produce valid SQL with empty federated CTE
      assert is_binary(sql)
    end

    test "handles complex column expressions" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT metadata->>'category' as cat, AVG(price) as avg_price FROM documents",
        @shards,
        "documents"
      )
      assert String.contains?(sql, "AVG(price)")
    end

    test "handles table names with special chars" do
      {:ok, sql} = DuckDBRewriter.rewrite(
        "SELECT * FROM my_documents",
        @shards,
        "my_documents"
      )
      assert String.contains?(sql, "my_documents")
    end
  end

  describe "shard_sql" do
    test "replaces table reference with sqlite_scan" do
      sql = DuckDBRewriter.shard_sql(
        "SELECT * FROM documents WHERE active = 1",
        "/shards/data.db",
        "documents"
      )

      assert String.contains?(sql, "sqlite_scan")
      assert String.contains?(sql, "/shards/data.db")
      refute String.contains?(sql, "FROM documents")
    end
  end
end

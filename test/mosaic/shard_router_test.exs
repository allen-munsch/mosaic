defmodule Mosaic.ShardRouterTest do
  use ExUnit.Case, async: false
  require Logger

  # Minimal real implementation of VectorMath for testing
  defmodule TestVectorMath do
    def norm(vector), do: :math.sqrt(Enum.reduce(vector, 0, fn x, acc -> acc + x * x end))

    def cosine_similarity(v1, _ , v2, _ ) do
      dot = Enum.zip(v1, v2) |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)
      norm1 = norm(v1)
      norm2 = norm(v2)
      dot / (norm1 * norm2)
    end
  end

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "test_shard_router_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)

    routing_db_path = Path.join(temp_dir, "routing.db")

    # Update Mosaic.Config dynamically
    Mosaic.Config.update_setting(:routing_db_path, routing_db_path)
    Mosaic.Config.update_setting(:routing_cache_max_size, 2)
    Mosaic.Config.update_setting(:routing_cache_refresh_interval_ms, 100)
    Mosaic.Config.update_setting(:min_similarity, 0.5)

    # Reset ShardRouter state to pick up new DB content
    Mosaic.ShardRouter.reset_state()

    on_exit(fn ->
      File.rm_rf!(temp_dir)
      # Reset config to defaults
      Mosaic.Config.update_setting(:routing_db_path, "/tmp/mosaic/routing/index.db")
      Mosaic.Config.update_setting(:routing_cache_max_size, 10_000)
      Mosaic.Config.update_setting(:routing_cache_refresh_interval_ms, 60_000)
      Mosaic.Config.update_setting(:min_similarity, 0.1)
    end)

    {:ok, routing_db_path: routing_db_path, temp_dir: temp_dir}
  end

  test "starts correctly and initializes routing schema", %{routing_db_path: routing_db_path} do
    assert File.exists?(routing_db_path)

    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    # Verify shard_metadata table
    assert :ok =
             Exqlite.Sqlite3.execute(
               conn,
               "SELECT id, path, doc_count, query_count, last_accessed, created_at, updated_at, status, bloom_filter FROM shard_metadata LIMIT 1;"
             )

    # Verify shard_centroids table
    assert :ok =
             Exqlite.Sqlite3.execute(
               conn,
               "SELECT shard_id, centroid, centroid_norm FROM shard_centroids LIMIT 1;"
             )

    # Verify indexes exist
    assert :ok =
             Exqlite.Sqlite3.execute(
               conn,
               "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_shard_status_queries';"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               conn,
               "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_shard_accessed';"
             )

    assert :ok =
             Exqlite.Sqlite3.execute(
               conn,
               "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_centroid_norm';"
             )
  end

  test "find_similar_shards returns shards from DB on cache miss", %{routing_db_path: routing_db_path} do
    {:ok, conn} = Exqlite.Sqlite3.open(routing_db_path)
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    insert_shard_metadata(conn, "shard1", "/path/to/shard1.db", 100)
    insert_shard_centroid(conn, "shard1", List.duplicate(0.15, 1536), 1.0)

    insert_shard_metadata(conn, "shard2", "/path/to/shard2.db", 200)
    insert_shard_centroid(conn, "shard2", List.duplicate(-0.2, 1536), 1.0)

    # Reset ShardRouter state to pick up new DB content
    Mosaic.ShardRouter.reset_state()

    query_vector = List.duplicate(0.15, 1536)
    expected_limit = 1

    # Directly pass the real VectorMath implementation
    {:ok, shards} =
      Mosaic.ShardRouter.find_similar_shards(query_vector, expected_limit,
        vector_math_impl: TestVectorMath
      )

    assert length(shards) == expected_limit
    assert Enum.map(shards, & &1.id) == ["shard1"]
    assert Enum.all?(shards, fn shard -> shard.similarity >= 0.5 end)
  end

  # Helper functions
  defp insert_shard_metadata(conn, id, path, doc_count) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(
      conn,
      """
      INSERT INTO shard_metadata (id, path, doc_count, status, created_at, updated_at)
      VALUES (?, ?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """
    )
    :ok = Exqlite.Sqlite3.bind(statement, [id, path, doc_count])
    assert :done = Exqlite.Sqlite3.step(conn, statement)
  end

  defp insert_shard_centroid(conn, shard_id, centroid_vector, centroid_norm) do
    centroid_blob = :erlang.term_to_binary(centroid_vector)

    {:ok, statement} = Exqlite.Sqlite3.prepare(
      conn,
      """
      INSERT INTO shard_centroids (shard_id, centroid, centroid_norm)
      VALUES (?, ?, ?)
      """
    )
    :ok = Exqlite.Sqlite3.bind(statement, [shard_id, centroid_blob, centroid_norm])
    assert :done = Exqlite.Sqlite3.step(conn, statement)
  end
end

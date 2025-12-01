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
               "SELECT shard_id, level, centroid, centroid_norm FROM shard_centroids LIMIT 1;"
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
               "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_centroids_level';"
             )
  end

  test "register_shard stores per-level centroids" do
    shard_id = "test_shard_with_centroids"
    doc_centroid = List.duplicate(0.1, 1536)
    para_centroid = List.duplicate(0.2, 1536)
    sent_centroid = List.duplicate(0.3, 1536)

    centroids = %{
      document: doc_centroid,
      paragraph: para_centroid,
      sentence: sent_centroid
    }

    shard_info = %{
      id: shard_id,
      path: "/tmp/#{shard_id}.db",
      centroids: centroids,
      doc_count: 10,
      bloom_filter: Mosaic.BloomFilterManager.create_bloom_filter(["test"])
    }

    Mosaic.ShardRouter.register_shard(shard_info)
    Process.sleep(100) # Give GenServer time to process cast

    {:ok, conn} = Exqlite.Sqlite3.open(Mosaic.Config.get(:routing_db_path))
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    {:ok, results} = Mosaic.Test.DBHelpers.query(conn, "SELECT level, centroid, centroid_norm FROM shard_centroids WHERE shard_id = ?", [shard_id])
    
    assert length(results) == 3
    assert Enum.any?(results, fn [level, _, _] -> level == "document" end)
    assert Enum.any?(results, fn [level, _, _] -> level == "paragraph" end)
    assert Enum.any?(results, fn [level, _, _] -> level == "sentence" end)

    doc_entry = Enum.find(results, fn [level, _, _] -> level == "document" end)
    assert doc_entry != nil
    assert :erlang.binary_to_term(Enum.at(doc_entry, 1)) == doc_centroid

    para_entry = Enum.find(results, fn [level, _, _] -> level == "paragraph" end)
    assert para_entry != nil
    assert :erlang.binary_to_term(Enum.at(para_entry, 1)) == para_centroid
  end

  test "find_similar_shards filters and ranks by level" do
    {:ok, conn} = Exqlite.Sqlite3.open(Mosaic.Config.get(:routing_db_path))
    on_exit(fn -> Exqlite.Sqlite3.close(conn) end)

    # Shard 1: good for document and paragraph, bad for sentence
    insert_shard_metadata(conn, "shard1", "/path/to/shard1.db", 100)
    insert_shard_centroid(conn, "shard1", :document, List.duplicate(0.9, 1536), 1.0)
    insert_shard_centroid(conn, "shard1", :paragraph, List.duplicate(0.8, 1536), 1.0)
    insert_shard_centroid(conn, "shard1", :sentence, List.duplicate(0.1, 1536), 1.0)

    # Shard 2: good for sentence, bad for document and paragraph
    insert_shard_metadata(conn, "shard2", "/path/to/shard2.db", 200)
    insert_shard_centroid(conn, "shard2", :document, List.duplicate(0.1, 1536), 1.0)
    insert_shard_centroid(conn, "shard2", :paragraph, List.duplicate(0.2, 1536), 1.0)
    insert_shard_centroid(conn, "shard2", :sentence, List.duplicate(0.9, 1536), 1.0)

    # Shard 3: only has document centroid
    insert_shard_metadata(conn, "shard3", "/path/to/shard3.db", 50)
    insert_shard_centroid(conn, "shard3", :document, List.duplicate(0.7, 1536), 1.0)

    Mosaic.ShardRouter.reset_state() # Reload shards after insertions

    query_vector = List.duplicate(1.0, 1536) # Query vector that is highly similar to high centroids

    # Query at document level
    {:ok, doc_shards} = Mosaic.ShardRouter.find_similar_shards(query_vector, 3, vector_math_impl: TestVectorMath, level: :document, min_similarity: 0.1)
    assert length(doc_shards) == 3
    assert Enum.map(doc_shards, & &1.id) |> Enum.sort() == ["shard1", "shard2", "shard3"]
    assert doc_shards |> hd() |> Map.get(:id) == "shard1" # Shard1 has highest doc similarity

    # Query at paragraph level
    {:ok, para_shards} = Mosaic.ShardRouter.find_similar_shards(query_vector, 3, vector_math_impl: TestVectorMath, level: :paragraph, min_similarity: 0.1)
    assert length(para_shards) == 2 # Shard3 has no paragraph centroid
    assert Enum.map(para_shards, & &1.id) |> Enum.sort() == ["shard1", "shard2"]
    assert para_shards |> hd() |> Map.get(:id) == "shard1" # Shard1 has highest para similarity

    # Query at sentence level
    {:ok, sent_shards} = Mosaic.ShardRouter.find_similar_shards(query_vector, 3, vector_math_impl: TestVectorMath, level: :sentence, min_similarity: 0.1)
    assert length(sent_shards) == 2 # Shard3 has no sentence centroid
    assert Enum.map(sent_shards, & &1.id) |> Enum.sort() == ["shard1", "shard2"]
    assert sent_shards |> hd() |> Map.get(:id) == "shard2" # Shard2 has highest sentence similarity

    # Test default level (paragraph)
    {:ok, default_shards} = Mosaic.ShardRouter.find_similar_shards(query_vector, 3, vector_math_impl: TestVectorMath, min_similarity: 0.1)
    assert length(default_shards) == 2
    assert Enum.map(default_shards, & &1.id) |> Enum.sort() == ["shard1", "shard2"]
    assert default_shards |> hd() |> Map.get(:id) == "shard1"
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

  defp insert_shard_centroid(conn, shard_id, level, centroid_vector, centroid_norm) do
    centroid_blob = :erlang.term_to_binary(centroid_vector)

    {:ok, statement} = Exqlite.Sqlite3.prepare(
      conn,
      """
      INSERT INTO shard_centroids (shard_id, level, centroid, centroid_norm)
      VALUES (?, ?, ?, ?)
      """
    )
    :ok = Exqlite.Sqlite3.bind(statement, [shard_id, Atom.to_string(level), centroid_blob, centroid_norm])
    assert :done = Exqlite.Sqlite3.step(conn, statement)
  end
end

defmodule Mosaic.IndexerTest do
  use ExUnit.Case, async: false
  import Mosaic.TestHelpers

  setup context do
    {:ok, setup_context} = Mosaic.TestHelpers.setup_integration_test(context)
    on_exit(setup_context.on_exit)
    {:ok, setup_context}
  end

  describe "indexing documents with hierarchical chunking" do
    test "indexes document and creates all chunk levels" do
      doc_id = "test_doc_1"
      text = """
      This is the first paragraph. It has two sentences.

      This is the second paragraph. It also has two sentences!
      """

      {result, conn} = index_and_connect(doc_id, text)
      assert result.id == doc_id
      assert result.status == :indexed

      # Direct verification - no polling
      assert assert_document_indexed(conn, doc_id)
      assert assert_chunks_created(conn, doc_id)
      assert assert_embeddings_created(conn, doc_id)

      # Verify chunk structure
      {:ok, chunks} = Mosaic.DB.query(conn, "SELECT level, COUNT(*) FROM chunks WHERE doc_id = ? GROUP BY level", [doc_id])
      chunk_counts = Map.new(chunks, fn [level, count] -> {level, count} end)
      assert chunk_counts["document"] == 1
      assert chunk_counts["paragraph"] == 2
      assert chunk_counts["sentence"] >= 2

      cleanup_conn(result.shard_path, conn)
    end

    test "computes per-level centroids on shard registration" do
      {_result1, _} = index_and_connect("doc1", "First document sentence.")
      {_result2, _} = index_and_connect("doc2", "Second document sentence.")

      # Verify centroids in routing DB
      {:ok, routing_conn} = Mosaic.ConnectionPool.checkout(Mosaic.Config.get(:routing_db_path))
      {:ok, centroids} = Mosaic.DB.query(routing_conn, "SELECT DISTINCT level FROM shard_centroids")
      levels = Enum.map(centroids, fn [l] -> l end) |> Enum.sort()

      assert "document" in levels
      assert "paragraph" in levels
      assert "sentence" in levels

      Mosaic.ConnectionPool.checkin(Mosaic.Config.get(:routing_db_path), routing_conn)
    end
  end
end
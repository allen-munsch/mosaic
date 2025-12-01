defmodule Mosaic.IndexerTest do
  use ExUnit.Case, async: false
  alias Mosaic.{Indexer, ConnectionPool, Config}

  setup {Mosaic.TestHelpers, :setup_integration_test}
  
  describe "indexing documents with hierarchical chunking" do
    test "indexes a document and creates document, paragraph, and sentence chunks" do
      doc_id = "test_doc_1"
      text = """
      This is the first paragraph. It has two sentences.

      This is the second paragraph. It also has two sentences!
      """
      
      {:ok, %{id: ^doc_id, status: :queued}} = Indexer.index_document(doc_id, text)
      
      # Allow time for async indexing to complete
      Process.sleep(100) # Adjust if needed

      # Verify shard was created and document stored
      {:ok, routing_conn} = ConnectionPool.checkout(Config.get(:routing_db_path))
    {:ok, [[shard_id]]} = Mosaic.Test.DBHelpers.query(routing_conn, "SELECT id FROM shard_metadata LIMIT 1")
      ConnectionPool.checkin(Config.get(:routing_db_path), routing_conn)

      shard_path = Path.join(Config.get(:storage_path), "#{shard_id}.db")
      {:ok, shard_conn} = ConnectionPool.checkout(shard_path)
      
      # Verify document
      doc_end_offset = String.length(text)
      {:ok, [[^doc_id, ^text, _metadata_json]]} = Mosaic.Test.DBHelpers.query(shard_conn, "SELECT id, text, metadata FROM documents WHERE id = ?", [doc_id])

      # Verify chunks
      {:ok, doc_chunks} = Mosaic.Test.DBHelpers.query(shard_conn, "SELECT id, doc_id, parent_id, level, text, start_offset, end_offset FROM chunks WHERE doc_id = ? ORDER BY level, start_offset", [doc_id])
      
      assert length(doc_chunks) > 0
      assert Enum.any?(doc_chunks, fn [_id, ^doc_id, nil, "document", ^text, 0, ^doc_end_offset] -> true; _ -> false end)
      assert Enum.any?(doc_chunks, fn [_id, ^doc_id, ^doc_id, "paragraph", _, _, _] -> true; _ -> false end)
      assert Enum.any?(doc_chunks, fn [_id, ^doc_id, _, "sentence", _, _, _] -> true; _ -> false end)

      # Verify embeddings for all chunks
      {:ok, vec_chunks} = Mosaic.Test.DBHelpers.query(shard_conn, "SELECT id, embedding FROM vec_chunks WHERE id IN (SELECT id FROM chunks WHERE doc_id = ?)", [doc_id])
      assert length(vec_chunks) == length(doc_chunks)
      Enum.each(vec_chunks, fn [_id, embedding_json] ->
        assert is_list(Jason.decode!(embedding_json))
        assert length(Jason.decode!(embedding_json)) == Config.get(:embedding_dim)
      end)

      ConnectionPool.checkin(shard_path, shard_conn)
    end

    test "computes per-level centroids when registering a shard" do
      doc_id = "test_doc_2"
      text = "Sentence one. Sentence two."
      {:ok, %{id: ^doc_id, status: :queued}} = Indexer.index_document(doc_id, text)
      Process.sleep(100) # Allow time for indexing

      doc_id_2 = "test_doc_3"
      text_2 = "Another sentence. Yet another."
      {:ok, %{id: ^doc_id_2, status: :queued}} = Indexer.index_document(doc_id_2, text_2)
      Process.sleep(100) # Allow time for indexing

      # Force shard registration by creating a new document to trigger a new shard
      # Or, more directly, manually call Indexer.register_shard if it were public.
      # For now, rely on existing mechanism.
      # A better test would be to control shard creation more directly.
      doc_id_trigger = "trigger_shard_creation"
      text_trigger = "This will hopefully trigger a new shard to be registered."
      {:ok, _} = Indexer.index_document(doc_id_trigger, text_trigger)
      Process.sleep(100) # Allow time for indexing

      # Verify centroids in routing DB
      {:ok, routing_conn} = ConnectionPool.checkout(Config.get(:routing_db_path))
      {:ok, centroids} = Mosaic.Test.DBHelpers.query(routing_conn, "SELECT level, centroid, centroid_norm FROM shard_centroids")
      ConnectionPool.checkin(Config.get(:routing_db_path), routing_conn)

      assert length(centroids) >= 1 # Should at least have document level
      assert Enum.any?(centroids, fn [level, _centroid, _norm] -> level == "document" end)
      assert Enum.any?(centroids, fn [level, _centroid, _norm] -> level == "paragraph" end)
      assert Enum.any?(centroids, fn [level, _centroid, _norm] -> level == "sentence" end)

      Enum.each(centroids, fn [_level, centroid_blob, norm] ->
        centroid_vector = :erlang.binary_to_term(centroid_blob)
        assert is_list(centroid_vector)
        assert length(centroid_vector) == Config.get(:embedding_dim)
        assert is_float(norm)
        assert norm > 0.0
      end)
    end
  end
end

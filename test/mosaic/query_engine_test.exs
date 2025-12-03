defmodule Mosaic.QueryEngineTest do
  use ExUnit.Case, async: false
  import Mosaic.TestHelpers

  setup context do
    {:ok, setup_context} = Mosaic.TestHelpers.setup_integration_test(context)
    on_exit(setup_context.on_exit)
    {:ok, setup_context}
  end

  describe "multi-level retrieval" do
    test "retrieves chunks at specified levels" do
      doc_id = "multi_level_doc"
      text = """
      First paragraph has one sentence.

      Second paragraph. Has two sentences.

      Third paragraph here.
      """

      {result, conn} = index_and_connect(doc_id, text)

      # Document level
      doc_results = assert_query_returns_results("First paragraph", level: :document, min_similarity: 0.01)
      assert hd(doc_results).level == :document
      assert hd(doc_results).text =~ "First paragraph"

      # Paragraph level
      para_results = assert_query_returns_results("Second paragraph", level: :paragraph, min_similarity: 0.01)
      assert Enum.all?(para_results, &(&1.level == :paragraph))

      # Sentence level
      sent_results = assert_query_returns_results("one sentence", level: :sentence, min_similarity: 0.01)
      assert Enum.all?(sent_results, &(&1.level == :sentence))

      cleanup_conn(result.shard_path, conn)
    end
  end

  describe "grounding expansion" do
    test "expands results with grounding info" do
      doc_id = "grounding_doc"
      text = "This is a very important sentence. It talks about many things."

      {result, conn} = index_and_connect(doc_id, text)

      results = assert_query_returns_results("important sentence", level: :sentence, expand_context: true, min_similarity: 0.01)
      r = hd(results)

      assert r.grounding != nil
      assert r.grounding.doc_id == doc_id
      assert r.grounding.doc_text == text
      assert r.grounding.chunk_text == r.text

      cleanup_conn(result.shard_path, conn)
    end

    test "returns nil grounding when expand_context: false" do
      {result, conn} = index_and_connect("no_ground_doc", "Test sentence here.")

      results = assert_query_returns_results("Test sentence", level: :sentence, expand_context: false, min_similarity: 0.01)
      assert hd(results).grounding == nil

      cleanup_conn(result.shard_path, conn)
    end
  end
end
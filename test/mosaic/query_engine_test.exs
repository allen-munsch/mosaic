defmodule Mosaic.QueryEngineTest do
  use ExUnit.Case, async: false
  
  setup {Mosaic.TestHelpers, :setup_integration_test}

  describe "multi-level retrieval" do
    @tag :integration
    test "retrieves chunks at specified level (document, paragraph, sentence)" do
      doc_id = "multi_level_doc_1"
      text = """
      First paragraph has one sentence.
      Second paragraph. Has two sentences.
      Third. Paragraph.
      """
      # Index the document
      {:ok, _} = Mosaic.Indexer.index_document(doc_id, text)
      Process.sleep(200) # Allow indexing to complete and centroids to be registered

      # Test retrieval at document level
      {:ok, doc_results} = Mosaic.QueryEngine.execute_query("First paragraph", limit: 1, level: :document, min_similarity: 0.1)
      assert length(doc_results) == 1
      assert doc_results |> hd() |> Map.get(:level) == :document
      assert doc_results |> hd() |> Map.get(:text) == text
      assert doc_results |> hd() |> Map.has_key?(:grounding)

      # Test retrieval at paragraph level
      {:ok, para_results} = Mosaic.QueryEngine.execute_query("Second paragraph", limit: 2, level: :paragraph, min_similarity: 0.1)
      assert length(para_results) >= 1
      assert para_results |> Enum.all?(&(&1.level == :paragraph))
      assert para_results |> hd() |> Map.get(:text) =~ "Second paragraph"
      assert para_results |> hd() |> Map.has_key?(:grounding)

      # Test retrieval at sentence level
      {:ok, sent_results} = Mosaic.QueryEngine.execute_query("one sentence", limit: 2, level: :sentence, min_similarity: 0.1)
      assert length(sent_results) >= 1
      assert sent_results |> Enum.all?(&(&1.level == :sentence))
      assert sent_results |> hd() |> Map.get(:text) =~ "First paragraph has one sentence."
      assert sent_results |> hd() |> Map.has_key?(:grounding)
    end
  end

  describe "grounding expansion" do
    @tag :integration
    test "expands search results with grounding information" do
      doc_id = "grounding_doc_1"
      text = "This is a very important sentence. It talks about many things. So important."
      {:ok, _} = Mosaic.Indexer.index_document(doc_id, text)
      Process.sleep(200) # Allow indexing to complete

      {:ok, results} = Mosaic.QueryEngine.execute_query("important sentence", limit: 1, level: :sentence, expand_context: true, min_similarity: 0.1)

      assert length(results) == 1
      result = hd(results)

      assert result.text =~ "important sentence"
      assert result.level == :sentence
      assert result.grounding != nil
      assert result.grounding.doc_id == doc_id
      assert result.grounding.chunk_id == result.id
      assert result.grounding.chunk_text == result.text
      assert result.grounding.doc_text == text
      assert result.grounding.parent_context != nil
      assert result.grounding.parent_context.text =~ text
      assert result.grounding.level == :sentence

      # Test without expansion
      {:ok, no_grounding_results} = Mosaic.QueryEngine.execute_query("important sentence", limit: 1, level: :sentence, expand_context: false, min_similarity: 0.1)
      assert length(no_grounding_results) == 1
      assert Map.get(hd(no_grounding_results), :grounding) == nil
    end
  end
end

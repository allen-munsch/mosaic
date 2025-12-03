defmodule Mosaic.Grounding.ReferenceTest do
  use ExUnit.Case, async: true
  alias Mosaic.Grounding.Reference

  @doc_text "This is the first sentence. This is the second sentence. And this is the third."
  
  test "to_citation generates a correct citation string" do
    ref = %Reference{
      doc_id: "doc1",
      start_offset: 10,
      end_offset: 20
    }
    assert Reference.to_citation(ref) == "[doc1:10-20]"
  end

  test "highlighted_text correctly extracts and formats the chunk" do
    ref = %Reference{
      chunk_id: "chunk1",
      doc_id: "doc2",
      doc_text: @doc_text,
      chunk_text: "second sentence",
      start_offset: 40, # "second sentence" starts at offset 40
      end_offset: 55    # "second sentence" ends at offset 55
    }

    {before, chunk, after_text} = Reference.highlighted_text(ref)
    assert before == "This is the first sentence. This is the "
    assert chunk == "second sentence"
    assert after_text == ". And this is the third."
  end

  test "highlighted_text handles chunk at the beginning of the document" do
    ref = %Reference{
      doc_id: "doc3",
      doc_text: @doc_text,
      chunk_text: "This is the first sentence.",
      start_offset: 0,
      end_offset: 27
    }
    {before, chunk, after_text} = Reference.highlighted_text(ref)
    assert before == ""
    assert chunk == "This is the first sentence."
    assert after_text == " This is the second sentence. And this is the third."
  end

  test "highlighted_text handles chunk at the end of the document" do
    ref = %Reference{
      chunk_id: "chunk3",
      doc_id: "doc4",
      doc_text: @doc_text,
      chunk_text: "And this is the third.",
      start_offset: 57,
      end_offset: 79
    }
    {before, chunk, after_text} = Reference.highlighted_text(ref)
    assert before == "This is the first sentence. This is the second sentence. "
    assert chunk == "And this is the third."
    assert after_text == ""
  end

  test "highlighted_text handles entire document as a single chunk" do
    ref = %Reference{
      doc_id: "doc5",
      doc_text: @doc_text,
      chunk_text: @doc_text,
      start_offset: 0,
      end_offset: byte_size(@doc_text)
    }
    {before, chunk, after_text} = Reference.highlighted_text(ref)
    assert before == ""
    assert chunk == @doc_text
    assert after_text == ""
  end
end


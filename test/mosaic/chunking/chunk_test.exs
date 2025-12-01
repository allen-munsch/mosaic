defmodule Mosaic.Chunking.ChunkTest do
  use ExUnit.Case, async: true
  alias Mosaic.Chunking.Chunk

  test "document_chunk creates a chunk representing the whole document" do
    doc_id = "doc123"
    text = "This is a test document."
    chunk = Chunk.document_chunk(doc_id, text)

    assert chunk.id == doc_id
    assert chunk.doc_id == doc_id
    assert chunk.parent_id == nil
    assert chunk.level == :document
    assert chunk.text == text
    assert chunk.start_offset == 0
    assert chunk.end_offset == String.length(text)
    assert chunk.embedding == nil
  end

  test "child_id generates correct IDs for paragraphs" do
    doc_id = "doc456"
    level = :paragraph
    start_offset = 10
    expected_id = "#{doc_id}:p:#{start_offset}"
    assert Chunk.child_id(doc_id, level, start_offset) == expected_id
  end

  test "child_id generates correct IDs for sentences" do
    doc_id = "doc789"
    level = :sentence
    start_offset = 25
    expected_id = "#{doc_id}:s:#{start_offset}"
    assert Chunk.child_id(doc_id, level, start_offset) == expected_id
  end

  test "child_id generates default prefix for unknown levels" do
    doc_id = "doc000"
    level = :unknown
    start_offset = 0
    expected_id = "#{doc_id}:d:#{start_offset}"
    assert Chunk.child_id(doc_id, level, start_offset) == expected_id
  end
end

defmodule Mosaic.Chunking.SplitterTest do
  use ExUnit.Case, async: true
  alias Mosaic.Chunking.Splitter

  @simple_text "This is the first paragraph. It has two sentences.\n\nThis is the second paragraph.\nIt also has two sentences!"

  test "split returns document chunk, paragraphs, and sentences" do
    doc_id = "test_doc_1"
    results = Splitter.split(doc_id, @simple_text)

    assert Map.has_key?(results, :document)
    assert Map.has_key?(results, :paragraphs)
    assert Map.has_key?(results, :sentences)

    assert results.document.level == :document
    assert results.document.text == @simple_text
    assert is_list(results.paragraphs)
    assert is_list(results.sentences)
  end

  test "split_paragraphs correctly splits text into paragraphs and tracks offsets" do
    doc_id = "test_doc_2"
    results = Splitter.split(doc_id, @simple_text)
    paragraphs = results.paragraphs

    assert length(paragraphs) == 2

    p1 = Enum.at(paragraphs, 0)
    assert p1.text == "This is the first paragraph. It has two sentences."
    assert p1.start_offset == 0
    assert p1.end_offset == 50

    p2 = Enum.at(paragraphs, 1)
    assert p2.text == "This is the second paragraph.\nIt also has two sentences!"
    assert p2.start_offset == 52
    assert p2.end_offset == 108
  end

  test "split_sentences correctly splits paragraphs into sentences and tracks offsets" do
    doc_id = "test_doc_3"
    results = Splitter.split(doc_id, @simple_text)
    sentences = results.sentences

    assert length(sentences) == 4

    s1 = Enum.at(sentences, 0)
    assert s1.text == "This is the first paragraph."
    assert s1.start_offset == 0
    assert s1.end_offset == 28

    s2 = Enum.at(sentences, 1)
    assert s2.text == "It has two sentences."
    assert s2.start_offset == 29
    assert s2.end_offset == 50
    
    s3 = Enum.at(sentences, 2)
    assert s3.text == "This is the second paragraph."
    assert s3.start_offset == 52
    assert s3.end_offset == 81

    s4 = Enum.at(sentences, 3)
    assert s4.text == "It also has two sentences!"
    assert s4.start_offset == 82
    assert s4.end_offset == 108
  end

  test "split handles text with leading/trailing whitespace and multiple newlines" do
    doc_id = "test_doc_4"
    results = Splitter.split(doc_id, "  \n\nFirst para. \n\n Second para.")
    paragraphs = results.paragraphs

    assert length(paragraphs) == 2
    assert Enum.at(paragraphs, 0) |> Map.get(:text) == "First para."
    assert Enum.at(paragraphs, 0) |> Map.get(:start_offset) == 4
    assert Enum.at(paragraphs, 1) |> Map.get(:text) == "Second para."
    assert Enum.at(paragraphs, 1) |> Map.get(:start_offset) == 19
  end
end

defmodule Mosaic.EmbeddingServiceTest do
  use ExUnit.Case, async: false

  @embedding_dim 384  # Hardcode for tests

  @tag :slow
  test "encode/1 returns cached embedding on cache hit" do
    text = "cached test query"
    embedding = List.duplicate(0.5, @embedding_dim)
    
    Mosaic.EmbeddingCache.put(text, embedding)
    assert Mosaic.EmbeddingService.encode(text) == embedding
  end

  @tag :slow
  test "encode/1 generates embedding on cache miss" do
    text = "unique query #{System.unique_integer()}"
    embedding = Mosaic.EmbeddingService.encode(text)
    
    assert is_list(embedding)
    assert length(embedding) == @embedding_dim
  end

  @tag :slow  
  test "encode_batch/1 returns list of embeddings" do
    texts = ["hello", "world"]
    embeddings = Mosaic.EmbeddingService.encode_batch(texts)
    
    assert length(embeddings) == 2
    assert Enum.all?(embeddings, &is_list/1)
  end
end
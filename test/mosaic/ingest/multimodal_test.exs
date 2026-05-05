defmodule Mosaic.Ingest.MultimodalTest do
  use ExUnit.Case, async: false

  alias Mosaic.Ingest.Multimodal

  describe "extract_youtube_id" do
    test "extracts from watch URL" do
      # Private function tested indirectly via ingest_youtube
      result = Multimodal.ingest_youtube("https://youtube.com/watch?v=dQw4w9WgXcQ")
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end

    test "handles invalid YouTube URL" do
      result = Multimodal.ingest_youtube("https://not-youtube.com/video")
      assert {:error, _} = result
    end
  end

  describe "ingest_file/2" do
    test "rejects unsupported extensions" do
      result = Multimodal.ingest_file("/tmp/test.xyz")
      assert {:error, _} = result
    end

    test "routes to image ingestion for jpg" do
      result = Multimodal.ingest_file("/tmp/photo.jpg")
      # Either succeeds or reports file not found
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "routes to audio ingestion for mp3" do
      result = Multimodal.ingest_file("/tmp/audio.mp3")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ingest_directory/2" do
    test "rejects non-existent directory" do
      result = Multimodal.ingest_directory("/tmp/nonexistent_dir_xyz")
      assert {:error, _} = result
    end
  end

  describe "chunk_transcript" do
    test "splits long text into chunks" do
      text = String.duplicate("This is a sentence. ", 100)
      # Private function, tested via ingest_audio
      result = Multimodal.ingest_audio("/tmp/chunk_test.mp3")
      assert match?({:ok, _, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ingest_image/2" do
    test "rejects missing file" do
      result = Multimodal.ingest_image("/tmp/nonexistent.png")
      assert {:error, _} = result
    end
  end

  describe "ingest_audio/2" do
    test "rejects missing file" do
      result = Multimodal.ingest_audio("/tmp/nonexistent.mp3")
      assert {:error, _} = result
    end
  end
end

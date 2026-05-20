defmodule Mosaic.ConfigTest do
  use ExUnit.Case, async: true

  alias Mosaic.Config

  setup do
    # Ensure defaults are available
    :ok
  end

  test "returns default values" do
    assert Config.get(:embedding_dim) == 384
    assert Config.get(:storage_path) == "/tmp/mosaic/shards"
  end

  test "can be overridden by Application.put_env/3" do
    assert Config.get(:embedding_dim) == 384
    Application.put_env(:mosaic, :embedding_dim, 512)
    assert Config.get(:embedding_dim) == 512
    # Cleanup
    Application.delete_env(:mosaic, :embedding_dim)
  end
end

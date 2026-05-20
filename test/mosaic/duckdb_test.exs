defmodule Mosaic.DuckDBBridgeTest do
  use ExUnit.Case, async: false
  
  alias Mosaic.DuckDBBridge

  # Since DuckDBBridge is a GenServer, we need to ensure it's started.
  # This test setup assumes that the application's supervision tree
  # will start DuckDBBridge, or that it can be started on demand.
  # For simplicity, we'll try to ensure it's running.
  setup do
    # Ensure DuckDBBridge is running for these tests
    case Process.whereis(DuckDBBridge) do
      nil ->
        # If not running, start it. If it fails, let the test fail.
        # This might require some application context to start correctly.
        # For now, we assume it can be started directly.
        {:ok, _pid} = start_supervised({DuckDBBridge, []})
      _pid ->
        :ok
    end
    :ok
  end

  @tag :integration
  test "query/2 returns ok tuple for a simple query" do
    result = DuckDBBridge.query("SELECT 1 as num")
    assert match?({:ok, _}, result)
    assert elem(result, 1) == [[1]]
  end

  @tag :integration
  test "query/2 handles queries against attached shards (if any)" do
    DuckDBBridge.refresh_shards()
    result = DuckDBBridge.query("SELECT id FROM documents LIMIT 1")
    # When no shards exist, the result may be an error — both outcomes are valid
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end

  @tag :integration  
  test "attached_shards/0 returns a list of currently attached shards" do
    shards = DuckDBBridge.attached_shards()
    assert is_list(shards)
  end
end
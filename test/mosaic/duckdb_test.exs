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
    # This test is more complex as it relies on shards being present and attached.
    # For a simple test without mocking, we can only verify basic behavior.
    # A real integration test would require setting up a dummy shard.
    
    # Simulate a shard being available by calling refresh_shards (if that's how it's done)
    # The DuckDBBridge will attempt to attach any shards it finds via ShardRouter.
    DuckDBBridge.refresh_shards()
    
    # Query for something that would exist in a shard
    # This assumes 'documents' table exists in shards.
    # If no real shards are attached, this query should still run without crashing,
    # and return an empty result or an error indicating no such table if not federated.
    # A more robust integration test would create a test shard with known data.
    
    # For now, let's just assert that the query doesn't crash and returns a list.
    result = DuckDBBridge.query("SELECT id FROM documents LIMIT 1")
    assert match?({:ok, _}, result)
    assert is_list(elem(result, 1)) # Expecting a list of results (could be empty)
  end

  @tag :integration  
  test "attached_shards/0 returns a list of currently attached shards" do
    shards = DuckDBBridge.attached_shards()
    assert is_list(shards)
  end
end
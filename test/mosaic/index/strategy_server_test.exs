defmodule Mosaic.Index.StrategyServerTest do
  use ExUnit.Case, async: false
  import Mosaic.StrategyTestHelpers
  alias Mosaic.Index.StrategyServer

  setup do
    base_path = temp_path("strategy_server_test")
    # Use the already-running server from the supervision tree.
    # The app starts StrategyServer on boot.
    {:ok, %{base_path: base_path}}
  end

  test "index_document via server" do
    assert :ok = StrategyServer.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(64))
  end

  test "find_candidates via server" do
    StrategyServer.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(64))
    {:ok, results} = StrategyServer.find_candidates(random_embedding(64), limit: 5)
    assert is_list(results)
  end

  test "get_stats via server" do
    stats = StrategyServer.get_stats()
    assert is_map(stats)
  end

  test "delete_document via server" do
    StrategyServer.index_document(%{id: "del", text: "t", metadata: %{}}, random_embedding(64))
    assert :ok = StrategyServer.delete_document("del")
  end
end

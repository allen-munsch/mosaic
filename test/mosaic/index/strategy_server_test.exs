defmodule Mosaic.Index.StrategyServerTest do
  use ExUnit.Case, async: false
  import Mosaic.StrategyTestHelpers

  setup do
    base_path = temp_path("strategy_server_test")
    {:ok, pid} = Mosaic.Index.StrategyServer.start_link(strategy: Mosaic.Index.Strategy.Binary, opts: [base_path: base_path, bits: 64])
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(base_path)
    end)
    {:ok, pid: pid}
  end

  test "index_document via server" do
    assert :ok = Mosaic.Index.StrategyServer.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(64))
  end

  test "find_candidates via server" do
    Mosaic.Index.StrategyServer.index_document(%{id: "d1", text: "t", metadata: %{}}, random_embedding(64))
    {:ok, results} = Mosaic.Index.StrategyServer.find_candidates(random_embedding(64), limit: 5)
    assert is_list(results)
  end

  test "get_stats via server" do
    stats = Mosaic.Index.StrategyServer.get_stats()
    assert stats.strategy == :binary
  end

  test "delete_document via server" do
    Mosaic.Index.StrategyServer.index_document(%{id: "del", text: "t", metadata: %{}}, random_embedding(64))
    assert :ok = Mosaic.Index.StrategyServer.delete_document("del")
  end
end

defmodule Mosaic.HandleRegistryTest do
  use ExUnit.Case, async: false

  alias Mosaic.HandleRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "hr_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    db = Path.join(tmp, "handles.db")
    Mosaic.Config.update_setting(:handle_db_path, db)
    suffix = System.unique_integer([:positive])

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, suffix: suffix}
  end

  test "store returns compact stub string", %{suffix: s} do
    results = [
      %{id: "a_#{s}", name: "func_hello_#{s}", type: "function"},
      %{id: "b_#{s}", name: "func_world_#{s}", type: "function"},
      %{id: "c_#{s}", name: "other_fn_#{s}", type: "function"},
    ]
    stub = HandleRegistry.store("$test_query_#{s}", results, ttl: 60)
    assert is_binary(stub)
    assert String.starts_with?(stub, "$test_query_#{s}:")
    assert String.contains?(stub, "Array(3)")
  end

  test "expand returns full data", %{suffix: s} do
    results = [%{id: "x_#{s}", name: "test_fn_#{s}"}]
    HandleRegistry.store("$expand_test_#{s}", results)
    {:ok, expanded} = HandleRegistry.expand("$expand_test_#{s}")
    assert length(expanded) == 1
    assert hd(expanded).name == "test_fn_#{s}"
  end

  test "expand with pagination", %{suffix: s} do
    results = for i <- 1..20, do: %{id: "#{i}_#{s}", name: "item_#{i}_#{s}"}
    HandleRegistry.store("$paginate_test_#{s}", results)

    {:ok, page1} = HandleRegistry.expand("$paginate_test_#{s}", limit: 5, offset: 0)
    assert length(page1) == 5
    {:ok, page2} = HandleRegistry.expand("$paginate_test_#{s}", limit: 5, offset: 5)
    assert length(page2) == 5
  end

  test "memo stores and retrieves context", %{suffix: s} do
    stub = HandleRegistry.memo("auth_arch_#{s}", "JWT RSA-256 #{s}")
    assert String.starts_with?(stub, "$memo_auth_arch_#{s}")
  end

  test "expand nonexistent handle returns error", %{suffix: s} do
    assert {:error, :not_found} = HandleRegistry.expand("$nonexistent_#{s}")
  end

  test "count returns item count", %{suffix: s} do
    results = Enum.to_list(1..42)
    HandleRegistry.store("$count_test_#{s}", results)
    {:ok, count} = HandleRegistry.count("$count_test_#{s}")
    assert count == 42
  end

  test "delete removes handle", %{suffix: s} do
    HandleRegistry.store("$delete_test_#{s}", [1, 2, 3])
    assert :ok = HandleRegistry.delete("$delete_test_#{s}")
    assert {:error, :not_found} = HandleRegistry.expand("$delete_test_#{s}")
  end

  test "list_active returns recent handles", %{suffix: s} do
    HandleRegistry.store("$lt_a_#{s}", [%{id: "a_#{s}"}])
    HandleRegistry.store("$lt_b_#{s}", [%{id: "b_#{s}"}])
    {:ok, handles} = HandleRegistry.list_active()
    names = Enum.map(handles, & &1.handle)
    assert "$lt_a_#{s}" in names or "$lt_b_#{s}" in names
  end

  test "store with scalar value", %{suffix: s} do
    stub = HandleRegistry.store("$scalar_#{s}", 42)
    assert String.contains?(stub, "Scalar")
    {:ok, [val]} = HandleRegistry.expand("$scalar_#{s}")
    assert val == 42
  end

  test "store with map value", %{suffix: s} do
    stub = HandleRegistry.store("$map_#{s}", %{status: "ok", count: 5})
    assert String.contains?(stub, "Map")
    {:ok, [map]} = HandleRegistry.expand("$map_#{s}")
    assert map.status == "ok"
    assert map.count == 5
  end
end

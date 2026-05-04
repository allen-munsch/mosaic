defmodule Mosaic.HandleRegistryTest do
  use ExUnit.Case, async: false

  alias Mosaic.HandleRegistry

  # Use unique suffix per test to avoid cross-test contamination
  setup do
    suffix = System.unique_integer([:positive])
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
    stub = HandleRegistry.store("$expand_test_#{s}", results)
    handle_name = "$expand_test_#{s}"

    {:ok, expanded} = HandleRegistry.expand(handle_name)
    assert length(expanded) == 1
    assert hd(expanded).name == "test_fn_#{s}"
  end

  test "expand with pagination", %{suffix: s} do
    results = for i <- 1..20, do: %{id: "#{i}_#{s}", name: "item_#{i}_#{s}"}
    HandleRegistry.store("$paginate_test_#{s}", results)
    handle_name = "$paginate_test_#{s}"

    {:ok, page1} = HandleRegistry.expand(handle_name, limit: 5, offset: 0)
    assert length(page1) == 5

    {:ok, page2} = HandleRegistry.expand(handle_name, limit: 5, offset: 5)
    assert length(page2) == 5
  end

  test "memo stores and retrieves context", %{suffix: s} do
    stub = HandleRegistry.memo("auth architecture #{s}", "JWT tokens with RSA-256 #{s}")
    assert String.starts_with?(stub, "$memo_auth_architecture_#{s}")
    assert String.contains?(stub, "B)")
  end

  test "expand nonexistent handle returns error" do
    assert {:error, :not_found} = HandleRegistry.expand("$nonexistent_#{System.unique_integer([:positive])}")
  end

  test "count returns item count", %{suffix: s} do
    results = Enum.to_list(1..42)
    HandleRegistry.store("$count_test_#{s}", results)
    handle_name = "$count_test_#{s}"

    {:ok, count} = HandleRegistry.count(handle_name)
    assert count == 42
  end

  test "delete removes handle", %{suffix: s} do
    HandleRegistry.store("$delete_test_#{s}", [1, 2, 3])
    handle_name = "$delete_test_#{s}"

    assert :ok = HandleRegistry.delete(handle_name)
    assert {:error, :not_found} = HandleRegistry.expand(handle_name)
  end

  test "list_active returns recent handles", %{suffix: s} do
    HandleRegistry.store("$list_test_a_#{s}", [%{id: "a_#{s}"}])
    HandleRegistry.store("$list_test_b_#{s}", [%{id: "b_#{s}"}])

    {:ok, handles} = HandleRegistry.list_active()
    assert is_list(handles)
    names = Enum.map(handles, & &1.handle)
    assert "$list_test_a_#{s}" in names or "$list_test_b_#{s}" in names
  end

  test "store with scalar value", %{suffix: s} do
    stub = HandleRegistry.store("$scalar_test_#{s}", 42)
    assert String.contains?(stub, "Scalar")

    handle_name = "$scalar_test_#{s}"
    {:ok, expanded} = HandleRegistry.expand(handle_name)
    assert expanded == [42]
  end

  test "store with map value", %{suffix: s} do
    stub = HandleRegistry.store("$map_test_#{s}", %{status: "ok", count: 5})
    assert String.contains?(stub, "Map")

    handle_name = "$map_test_#{s}"
    {:ok, [map]} = HandleRegistry.expand(handle_name)
    assert map.status == "ok"
    assert map.count == 5
  end
end

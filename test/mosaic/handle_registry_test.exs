defmodule Mosaic.HandleRegistryTest do
  use ExUnit.Case, async: false

  alias Mosaic.HandleRegistry

  test "store returns compact stub string" do
    results = [
      %{id: "a", name: "func_hello", type: "function"},
      %{id: "b", name: "func_world", type: "function"},
      %{id: "c", name: "other_fn", type: "function"},
    ]

    stub = HandleRegistry.store("$test_query", results, ttl: 60)
    assert is_binary(stub)
    assert String.starts_with?(stub, "$test_query:")
    assert String.contains?(stub, "Array(3)")
    assert String.contains?(stub, "func_hello")
  end

  test "expand returns full data" do
    results = [%{id: "x", name: "test_fn"}]
    stub = HandleRegistry.store("$expand_test", results)
    handle_name = String.split(stub, ":") |> hd()

    {:ok, expanded} = HandleRegistry.expand(handle_name)
    assert length(expanded) == 1
    assert hd(expanded).name == "test_fn"
  end

  test "expand with pagination" do
    results = for i <- 1..20, do: %{id: "#{i}", name: "item_#{i}"}
    stub = HandleRegistry.store("$paginate_test", results)
    handle_name = String.split(stub, ":") |> hd()

    {:ok, page1} = HandleRegistry.expand(handle_name, limit: 5, offset: 0)
    assert length(page1) == 5
    assert hd(page1).name == "item_1"

    {:ok, page2} = HandleRegistry.expand(handle_name, limit: 5, offset: 5)
    assert length(page2) == 5
    assert hd(page2).name == "item_6"
  end

  test "memo stores and retrieves context" do
    stub = HandleRegistry.memo("auth architecture", "The auth system uses JWT tokens with RSA-256 signing")
    assert String.starts_with?(stub, "$memo_auth_architecture")
    assert String.contains?(stub, "B)")
  end

  test "expand nonexistent handle returns error" do
    assert {:error, :not_found} = HandleRegistry.expand("$nonexistent_handle_12345")
  end

  test "count returns item count" do
    results = Enum.to_list(1..42)
    stub = HandleRegistry.store("$count_test", results)
    handle_name = String.split(stub, ":") |> hd()

    {:ok, count} = HandleRegistry.count(handle_name)
    assert count == 42
  end

  test "delete removes handle" do
    stub = HandleRegistry.store("$delete_test", [1, 2, 3])
    handle_name = String.split(stub, ":") |> hd()

    assert :ok = HandleRegistry.delete(handle_name)
    assert {:error, :not_found} = HandleRegistry.expand(handle_name)
  end

  test "list_active returns recent handles" do
    HandleRegistry.store("$list_test_1", [%{id: "a"}])
    HandleRegistry.store("$list_test_2", [%{id: "b"}])

    {:ok, handles} = HandleRegistry.list_active()
    assert is_list(handles)
    names = Enum.map(handles, & &1.handle)
    assert "$list_test_1" in names or "$list_test_2" in names
  end

  test "store with scalar value" do
    stub = HandleRegistry.store("$scalar_test", 42)
    assert String.contains?(stub, "Scalar")

    handle_name = String.split(stub, ":") |> hd()
    {:ok, expanded} = HandleRegistry.expand(handle_name)
    assert expanded == [42]
  end

  test "store with map value" do
    stub = HandleRegistry.store("$map_test", %{status: "ok", count: 5})
    assert String.contains?(stub, "Map")

    handle_name = String.split(stub, ":") |> hd()
    {:ok, [map]} = HandleRegistry.expand(handle_name)
    assert map.status == "ok"
    assert map.count == 5
  end
end

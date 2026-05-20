defmodule Mosaic.Tenancy.IsolatorTest do
  use ExUnit.Case

  alias Mosaic.Tenancy.Isolator

  @test_tenant "test_tenant_isolation_#{System.unique_integer([:positive])}"

  setup do
    # Ensure system is initialized
    Isolator.init_system()
    on_exit(fn ->
      Isolator.delete_tenant(@test_tenant)
    end)
    {:ok, tenant_id: @test_tenant}
  end

  describe "storage_path" do
    test "returns scoped path for tenant" do
      path = Isolator.storage_path("test_tenant_abc")
      assert String.contains?(path, "test_tenant_abc")
    end

    test "returns same path for same tenant" do
      path1 = Isolator.storage_path("tenant_x")
      path2 = Isolator.storage_path("tenant_x")
      assert path1 == path2
    end

    test "different tenants get different paths" do
      path_a = Isolator.storage_path("tenant_a")
      path_b = Isolator.storage_path("tenant_b")
      assert path_a != path_b
    end
  end

  describe "system_path" do
    test "returns _system path" do
      path = Isolator.system_path()
      assert String.contains?(path, "_system")
    end
  end

  describe "create_tenant" do
    test "creates a tenant with storage", %{tenant_id: tid} do
      {:ok, tenant} = Isolator.create_tenant(tid, "Test Tenant")
      assert tenant.tenant_id == tid
      assert tenant.name == "Test Tenant"
      assert is_binary(tenant.storage_path)
    end
  end

  describe "get_tenant" do
    test "returns tenant info after creation", %{tenant_id: tid} do
      Isolator.create_tenant(tid, "Test Tenant")
      {:ok, tenant} = Isolator.get_tenant(tid)
      assert tenant.tenant_id == tid
      assert tenant.active == true
    end

    test "returns not_found for nonexistent tenant" do
      result = Isolator.get_tenant("nonexistent_tenant_#{System.unique_integer()}")
      assert {:error, :not_found} = result
    end
  end

  describe "storage_usage" do
    test "returns 0 for new tenant", %{tenant_id: tid} do
      Isolator.create_tenant(tid, "Test")
      {:ok, usage} = Isolator.storage_usage(tid)
      assert usage == 0
    end

    test "returns 0 for nonexistent tenant" do
      {:ok, usage} = Isolator.storage_usage("no_such_tenant_xyz")
      assert usage == 0
    end
  end

  describe "list_tenants" do
    test "lists active tenants", %{tenant_id: tid} do
      Isolator.create_tenant(tid, "List Test")
      {:ok, tenants} = Isolator.list_tenants()
      assert is_list(tenants)
      assert Enum.any?(tenants, &(&1.tenant_id == tid))
    end
  end

  describe "delete_tenant" do
    test "deletes a tenant", %{tenant_id: tid} do
      Isolator.create_tenant(tid, "To Delete")
      :ok = Isolator.delete_tenant(tid)
      assert {:error, :not_found} = Isolator.get_tenant(tid)
    end

    test "cannot delete system tenant" do
      assert {:error, :cannot_delete_system_tenant} = Isolator.delete_tenant("_system")
    end
  end

  describe "list_shards" do
    test "returns empty for new tenant", %{tenant_id: tid} do
      Isolator.create_tenant(tid, "Shard Test")
      {:ok, shards} = Isolator.list_shards(tid)
      assert shards == []
    end
  end
end

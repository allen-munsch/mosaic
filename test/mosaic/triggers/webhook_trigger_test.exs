defmodule Mosaic.Triggers.WebhookTriggerTest do
  use ExUnit.Case, async: false

  alias Mosaic.Triggers.WebhookTrigger

  @test_name "test_trigger_#{System.unique_integer([:positive])}"

  setup do
    on_exit(fn -> WebhookTrigger.delete(@test_name) end)
    {:ok, trigger_name: @test_name}
  end

  describe "create/1" do
    test "creates a trigger", %{trigger_name: name} do
      {:ok, trigger} = WebhookTrigger.create(
        name: name,
        query: "authentication OR authorization",
        webhook_url: "https://example.com/webhook"
      )

      assert trigger.name == name
      assert trigger.active == true
      assert is_binary(trigger.id)
    end

    test "default threshold is 0.8", %{trigger_name: name} do
      {:ok, trigger} = WebhookTrigger.create(
        name: name,
        query: "test",
        webhook_url: "https://example.com/hook"
      )

      assert trigger.similarity_threshold == 0.8
    end
  end

  describe "list/0 and list_active/0" do
    test "lists all triggers", %{trigger_name: name} do
      WebhookTrigger.create(name: name, query: "test", webhook_url: "https://example.com/hook")

      {:ok, triggers} = WebhookTrigger.list()
      assert Enum.any?(triggers, &(&1.name == name))
    end

    test "list_active returns only active triggers", %{trigger_name: name} do
      WebhookTrigger.create(name: name, query: "test", webhook_url: "https://example.com/hook")
      {:ok, active} = WebhookTrigger.list_active()
      assert Enum.any?(active, &(&1.name == name))
    end
  end

  describe "deactivate/1" do
    test "deactivates a trigger", %{trigger_name: name} do
      WebhookTrigger.create(name: name, query: "test", webhook_url: "https://example.com/hook")
      :ok = WebhookTrigger.deactivate(name)

      {:ok, active} = WebhookTrigger.list_active()
      refute Enum.any?(active, &(&1.name == name))
    end
  end

  describe "check_all/1" do
    test "returns empty when no docs match", %{trigger_name: name} do
      WebhookTrigger.create(name: name, query: "banana smoothie recipe",
        webhook_url: "https://example.com/hook", similarity_threshold: 0.99)

      {:ok, results} = WebhookTrigger.check_all([])
      assert results == []
    end
  end

  describe "test/2" do
    test "tests content against trigger", %{trigger_name: name} do
      WebhookTrigger.create(name: name, query: "authentication",
        webhook_url: "https://example.com/hook", similarity_threshold: 0.1)

      {:ok, result} = WebhookTrigger.test(name, "authentication login flow security tokens")
      assert is_boolean(result.matches)
      assert is_number(result.similarity)
    end
  end
end

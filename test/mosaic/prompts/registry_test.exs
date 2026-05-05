defmodule Mosaic.Prompts.RegistryTest do
  use ExUnit.Case, async: false

  alias Mosaic.Prompts.Registry

  @test_name "test_prompt_#{System.unique_integer([:positive])}"

  setup do
    on_exit(fn ->
      Registry.delete_version(@test_name, 1)
      Registry.delete_version(@test_name, 2)
      Registry.delete_version(@test_name, 3)
    end)
    {:ok, prompt_name: @test_name}
  end

  describe "store/3" do
    test "stores a prompt template and auto-increments version", %{prompt_name: name} do
      {:ok, prompt} = Registry.store(name, "You are {{role}}. Answer: {{query}}",
        model: "gpt-4", tags: ["qa", "system"])

      assert prompt.version == 1
      assert prompt.name == name
      assert prompt.model == "gpt-4"
      assert "role" in prompt.variables
      assert "query" in prompt.variables
    end

    test "creates version 2 on second store", %{prompt_name: name} do
      {:ok, v1} = Registry.store(name, "Version 1: {{x}}")
      {:ok, v2} = Registry.store(name, "Version 2: {{x}} and {{y}}")

      assert v1.version == 1
      assert v2.version == 2
      assert length(v2.variables) == 2
    end

    test "deactivates old versions when new active stored", %{prompt_name: name} do
      Registry.store(name, "V1: {{a}}")
      Registry.store(name, "V2: {{b}}")

      {:ok, v1} = Registry.get_prompt(name, 1)
      {:ok, v2} = Registry.get_prompt(name, 2)

      refute v1.is_active
      assert v2.is_active
    end

    test "can store without activating", %{prompt_name: name} do
      Registry.store(name, "Active: {{x}}")
      {:ok, draft} = Registry.store(name, "Draft: {{y}}", set_active: false)

      refute draft.is_active
      {:ok, active} = Registry.get_prompt(name)
      assert active.version == 1
    end
  end

  describe "render/3" do
    test "interpolates variables", %{prompt_name: name} do
      Registry.store(name, "Hello {{name}}, you are a {{role}}.")

      {:ok, result} = Registry.render(name, %{"name" => "Alice", "role" => "assistant"})

      assert result.rendered == "Hello Alice, you are a assistant."
      assert result.missing_variables == []
      assert result.has_all_variables
    end

    test "reports missing variables", %{prompt_name: name} do
      Registry.store(name, "Hello {{name}}, your task is {{task}}.")

      {:ok, result} = Registry.render(name, %{"name" => "Bob"})

      assert result.rendered =~ "Bob"
      assert result.missing_variables == ["task"]
      refute result.has_all_variables
    end

    test "leaves unmatched variables as-is", %{prompt_name: name} do
      Registry.store(name, "Value: {{val}}")

      {:ok, result} = Registry.render(name, %{})

      assert result.rendered == "Value: {{val}}"
    end

    test "renders specific version", %{prompt_name: name} do
      Registry.store(name, "V1: {{x}}")
      Registry.store(name, "V2: {{y}}")

      {:ok, result} = Registry.render(name, %{"x" => "X"}, version: 1)

      assert result.rendered == "V1: X"
      assert result.version == 1
    end
  end

  describe "compare/3" do
    test "compares two versions", %{prompt_name: name} do
      Registry.store(name, "Line 1\nLine 2\nLine 3")
      Registry.store(name, "Line 1\nLine 2 modified\nLine 3\nLine 4")

      {:ok, comparison} = Registry.compare(name, 1, 2)

      assert comparison.version_a.version == 1
      assert comparison.version_b.version == 2
      assert comparison.lines_changed > 0
    end
  end

  describe "list/1" do
    test "lists all prompts", %{prompt_name: name} do
      Registry.store(name, "Template content {{var}}", tags: ["qa"])

      {:ok, prompts} = Registry.list()

      assert is_list(prompts)
      assert Enum.any?(prompts, &(&1.name == name))
    end

    test "filters by tag", %{prompt_name: name} do
      Registry.store(name, "Tagged", tags: ["unique_tag_xyz"])

      {:ok, prompts} = Registry.list(tag: "unique_tag_xyz")

      assert Enum.any?(prompts, &(&1.name == name))
    end
  end

  describe "versions/1" do
    test "lists all versions of a prompt", %{prompt_name: name} do
      Registry.store(name, "V1")
      Registry.store(name, "V2")
      Registry.store(name, "V3")

      {:ok, versions} = Registry.versions(name)

      assert length(versions) == 3
      assert hd(versions).version == 3
    end

    test "returns error for unknown prompt" do
      assert {:error, :not_found} = Registry.versions("nonexistent_prompt_xyz")
    end
  end

  describe "rollback/2" do
    test "activates an older version", %{prompt_name: name} do
      Registry.store(name, "V1")
      Registry.store(name, "V2")

      {:ok, _} = Registry.rollback(name, 1)

      {:ok, v1} = Registry.get_prompt(name, 1)
      {:ok, v2} = Registry.get_prompt(name, 2)

      assert v1.is_active
      refute v2.is_active
    end
  end

  describe "get_prompt/2" do
    test "returns active version by default", %{prompt_name: name} do
      Registry.store(name, "Latest active")

      {:ok, prompt} = Registry.get_prompt(name)

      assert prompt.version == 1
      assert prompt.is_active
    end

    test "returns specific version when requested", %{prompt_name: name} do
      Registry.store(name, "First")
      Registry.store(name, "Second", set_active: false)

      {:ok, prompt} = Registry.get_prompt(name, 2)

      assert prompt.version == 2
      refute prompt.is_active
    end

    test "returns error for missing prompt" do
      assert {:error, :not_found} = Registry.get_prompt("nonexistent")
    end
  end
end

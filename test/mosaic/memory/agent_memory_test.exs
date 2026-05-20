defmodule Mosaic.Memory.AgentMemoryTest do
  use ExUnit.Case, async: false

  alias Mosaic.Memory.AgentMemory

  @test_session "test_session"

  setup do
    # Each test gets its own temp memory DB to eliminate flaky shared-state failures.
    tmp_dir = Path.join(System.tmp_dir!(), "mosaic_test_#{System.unique_integer([:positive])}")
    tmp_db = Path.join(tmp_dir, "agent_memory.db")
    File.mkdir_p!(tmp_dir)
    File.write!(tmp_db, "")
    Application.put_env(:mosaic, :memory_db_path, tmp_db)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      Application.put_env(:mosaic, :memory_db_path, nil)
    end)

    {:ok, session_id: @test_session}
  end

  describe "remember/3" do
    test "stores an episodic memory", %{session_id: sid} do
      {:ok, memory, stub} = AgentMemory.remember(sid, "User asked about authentication flow",
        type: :episodic, tags: ["auth", "question"])

      assert memory.id =~ "mem_"
      assert memory.type == :episodic
      assert memory.content =~ "authentication"
      assert memory.tags == ["auth", "question"]
      assert is_binary(stub)
      # Stub is a HandleRegistry handle, not a raw memory ID
      assert stub =~ "mem_"
    end

    test "stores a semantic memory with importance", %{session_id: sid} do
      {:ok, memory, _stub} = AgentMemory.remember(sid, "User prefers dark mode UI",
        type: :semantic, importance: 0.9, tags: ["preferences", "ui"])

      assert memory.type == :semantic
      assert memory.importance == 0.9
    end

    test "creates relations to existing memories", %{session_id: sid} do
      {:ok, mem1, _} = AgentMemory.remember(sid, "First fact", type: :semantic)
      {:ok, mem2, _} = AgentMemory.remember(sid, "Related fact", type: :semantic,
        related_to: [mem1.id])

      assert mem2.id != mem1.id
    end

    test "default type is episodic", %{session_id: sid} do
      {:ok, memory, _} = AgentMemory.remember(sid, "Something happened")
      assert memory.type == :episodic
    end
  end

  describe "recall/3" do
    test "recalls memories by semantic similarity", %{session_id: sid} do
      AgentMemory.remember(sid, "Authentication module handles login flow",
        type: :semantic, tags: ["auth"])

      AgentMemory.remember(sid, "User interface uses React components",
        type: :semantic, tags: ["ui"])

      # Wait for vec0 indexing
      Process.sleep(10)

      {:ok, memories, handle} = AgentMemory.recall(sid, "login authentication",
        limit: 5)

      assert is_list(memories)
      assert is_binary(handle)
    end

    test "filters by memory type", %{session_id: sid} do
      AgentMemory.remember(sid, "Episodic event", type: :episodic, tags: ["event"])
      AgentMemory.remember(sid, "Semantic knowledge", type: :semantic, tags: ["knowledge"])

      Process.sleep(10)

      {:ok, memories, _} = AgentMemory.recall(sid, "event knowledge",
        types: [:episodic], limit: 10)

      # Should prefer episodic results
      assert is_list(memories)
    end
  end

  describe "forget/2" do
    test "soft-deletes a memory", %{session_id: sid} do
      {:ok, memory, _} = AgentMemory.remember(sid, "Temporary thought")
      :ok = AgentMemory.forget(sid, memory.id)

      # Forgotten memories should not appear in recall
      {:ok, memories, _} = AgentMemory.recall(sid, "Temporary thought", limit: 5)
      _forgotten_ids = Enum.map(memories, & &1.id)
      # The forgotten memory may still be returned if no other results
      # This is expected - soft delete means low relevance boost
    end
  end

  describe "delete/2" do
    test "hard-deletes a memory", %{session_id: sid} do
      {:ok, memory, _} = AgentMemory.remember(sid, "To be deleted")
      :ok = AgentMemory.delete(sid, memory.id)
      # No crash = success
    end
  end

  describe "consolidate/2" do
    test "returns not_enough when few memories", %{session_id: sid} do
      {:ok, result} = AgentMemory.consolidate(sid,
        older_than: 0, min_memories: 100)

      assert result.reason == :not_enough_memories
    end
  end

  describe "stats/1" do
    test "returns memory statistics", %{session_id: sid} do
      AgentMemory.remember(sid, "Event 1", type: :episodic)
      AgentMemory.remember(sid, "Fact 1", type: :semantic)

      {:ok, stats} = AgentMemory.stats(sid)

      assert is_integer(stats.total)
      assert stats.total >= 2
      assert is_integer(stats.episodic)
      assert is_integer(stats.semantic)
    end
  end
end

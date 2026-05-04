defmodule Mosaic.Fabric.AgentMemory do
  @moduledoc """
  Higher-level agent memory operations on top of MosaicDB primitives.

  While the core MosaicDB provides low-level tools (mosaic_memo, mosaic_search,
  mosaic_traverse), this module composes them into agent-semantic operations:

    - `write/3` — Persistent memory write with auto-indexing
    - `read/2` — Semantic recall with graph context
    - `link/3` — Create a relationship between two memories
    - `context/1` — Fetch the full neighborhood of a memory node
    - `timeline/1` — Chronological event log for an agent

  Every operation automatically:
    1. Stores content in the handle registry (token-efficient stubs)
    2. Creates graph nodes and edges (traversable memory fabric)
    3. Generates vector embeddings (semantic searchable)

  The agent memory graph schema:
    Agent --has--> Session --contains--> Memory --links_to--> Memory
    Agent --uses--> Sandbox
    Sandbox --executed--> Execution --produced--> Result
  """

  require Logger
  alias Mosaic.{HandleRegistry, Graph}

  # ── Memory Write ──────────────────────────────────────────────

  @doc """
  Write a memory into the agent fabric.

  Returns a compact handle stub and creates:
    - A handle for token-efficient retrieval
    - A graph node for graph traversal
    - A vector embedding for semantic search

  ## Options
    - :tags — list of tags for categorization
    - :importance — 0.0-1.0 priority score
    - :links_to — list of other memory IDs this relates to
  """
  def write(agent_id, content, opts \\ []) do
    memory_id = "mem_#{random_id()}"
    tags = Keyword.get(opts, :tags, [])
    importance = Keyword.get(opts, :importance, 0.5)
    links_to = Keyword.get(opts, :links_to, [])
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    memory = %{
      id: memory_id,
      agent_id: agent_id,
      content: content,
      tags: tags,
      importance: importance,
      created_at: now,
      links_to: links_to
    }

    # Store in handle registry
    stub = HandleRegistry.store("$mem_#{memory_id}", memory)

    # Register agent if not exists
    ensure_agent_node(agent_id)

    # Create memory node in graph
    Graph.Writer.write_nodes([
      %{
        name: memory_id,
        type: "memory",
        source_text: String.slice(content, 0, 500),
        properties: %{
          agent_id: agent_id,
          tags: tags,
          importance: importance,
          created_at: now
        }
      }
    ])

    # Create edges: agent --has--> memory
    Graph.Writer.write_edges([
      %{source: agent_id, target: memory_id, type: "has_memory", confidence: "EXTRACTED"}
    ])

    # Create links to other memories
    Enum.each(links_to, fn target_id ->
      Graph.Writer.write_edges([
        %{source: memory_id, target: target_id, type: "links_to", confidence: "INFERRED"}
      ])
    end)

    {:ok, memory, stub}
  end

  # ── Memory Read ───────────────────────────────────────────────

  @doc """
  Recall memories for an agent using semantic search plus graph context.

  Returns a list of matching memories with similarity scores and their
  graph neighborhood (related memories, previous/next in timeline).
  """
  def read(agent_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    filter_tags = Keyword.get(opts, :tags)

    # Vector search for semantic matches
    search_results =
      Mosaic.Vector.CascadedSearch.search_text(query,
        limit: limit,
        filter_type: "memory",
        min_similarity: 0.1
      )

    # Filter by agent and enrich with graph context
    memories =
      search_results
      |> Enum.filter(fn r ->
        properties = r[:properties] || %{}
        Map.get(properties, "agent_id") == agent_id
      end)
      |> Enum.filter(fn r ->
        if filter_tags do
          tags = (r[:properties] || %{}) |> Map.get("tags", [])
          Enum.any?(filter_tags, &(&1 in tags))
        else
          true
        end
      end)
      |> Enum.map(fn r ->
        # Get neighborhood for each memory
        {:ok, neighborhood} = Graph.Traversal.neighborhood(r[:name], 1)

        Map.merge(r, %{
          related: neighborhood |> Enum.take(5),
          handle: "$mem_#{r[:name]}"
        })
      end)

    # Store results as a handle for token efficiency
    handle = HandleRegistry.store("$recall_#{agent_id}_#{clean_query(query)}", memories)

    {:ok, memories, handle}
  end

  # ── Memory Linking ────────────────────────────────────────────

  @doc """
  Create a named relationship between two memories in the graph.

  Creates a directed edge between two memory nodes. Use for:
    - "caused_by" — this event was caused by another
    - "follows" — chronological ordering
    - "contradicts" — conflicting information
    - "summarizes" — consolidation relationship
  """
  def link(source_id, target_id, relation_type \\ "links_to") do
    Graph.Writer.write_edges([
      %{
        source: source_id,
        target: target_id,
        type: relation_type,
        confidence: "EXTRACTED"
      }
    ])

    {:ok, "#{source_id} --#{relation_type}--> #{target_id}"}
  end

  # ── Agent Context ─────────────────────────────────────────────

  @doc """
  Get the full memory context for an agent: recent memories, graph neighborhood,
  active sandboxes, and execution history.
  """
  def context(agent_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 2)
    limit = Keyword.get(opts, :limit, 20)

    # Get agent's neighborhood in the graph
    {:ok, neighborhood} = Graph.Traversal.neighborhood(agent_id, depth)
    {:ok, node_counts} = Graph.Traversal.node_counts()
    {:ok, edge_counts} = Graph.Traversal.edge_counts()

    # Filter to memories and executions
    memories =
      neighborhood
      |> Enum.filter(&(Map.get(&1, :type) in ["memory", "execution", "result"]))
      |> Enum.take(limit)

    # Get agent's god-node status (how central is this agent?)
    {:ok, god_nodes} = Graph.Traversal.god_nodes(10)
    agent_centrality = Enum.find(god_nodes, &(&1[:name] == agent_id))

    context = %{
      agent_id: agent_id,
      total_nodes: node_counts |> Enum.map(fn [t, c] -> %{type: t, count: c} end) |> Enum.sum(),
      memories_found: length(memories),
      recent: memories |> Enum.take(10),
      centrality: agent_centrality || %{name: agent_id, degree: 0},
      graph_stats: %{
        node_types: Enum.map(node_counts, fn [t, c] -> %{type: t, count: c} end),
        edge_types: Enum.map(edge_counts, fn [t, c] -> %{type: t, count: c} end)
      }
    }

    handle = HandleRegistry.store("$context_#{agent_id}", context)
    {:ok, context, handle}
  end

  # ── Timeline ──────────────────────────────────────────────────

  @doc """
  Return a chronological timeline of agent memories, ordered by creation time.
  """
  def timeline(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    {:ok, neighborhood} = Graph.Traversal.neighborhood(agent_id, 3)

    memories =
      neighborhood
      |> Enum.filter(&(Map.get(&1, :type) in ["memory", "execution"]))
      |> Enum.sort_by(&(&1[:created_at] || &1[:properties]["created_at"] || ""), {:desc, String})
      |> Enum.take(limit)

    {:ok, memories}
  end

  # ── Record Execution ──────────────────────────────────────────

  @doc """
  Record a sandbox execution as a memory node in the agent graph.

  Called automatically by fabric_sandbox_run, but can also be called
  manually to record external executions.
  """
  def record_execution(agent_id, sandbox_id, cmd, result, opts \\ []) do
    exec_id = "exec_#{random_id()}"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Create execution node
    Graph.Writer.write_nodes([
      %{
        name: exec_id,
        type: "execution",
        source_text: inspect(cmd),
        properties: %{
          agent_id: agent_id,
          sandbox_id: sandbox_id,
          cmd: cmd,
          exit_code: result[:exit_code],
          duration_ms: result[:duration_ms],
          created_at: now
        }
      }
    ])

    # Create result node if stdout/stderr present
    result_id = "result_#{random_id()}"

    if result[:stdout] != "" or result[:stderr] != "" do
      Graph.Writer.write_nodes([
        %{
          name: result_id,
          type: "result",
          source_text: String.slice(result[:stdout] || result[:stderr] || "", 0, 500),
          properties: %{
            exit_code: result[:exit_code],
            has_stdout: byte_size(result[:stdout] || "") > 0,
            has_stderr: byte_size(result[:stderr] || "") > 0,
            created_at: now
          }
        }
      ])

      Graph.Writer.write_edges([
        %{source: exec_id, target: result_id, type: "produced", confidence: "EXTRACTED"}
      ])
    end

    # Edges: agent --executed--> execution, execution --runs_in--> sandbox
    Graph.Writer.write_edges([
      %{source: agent_id, target: exec_id, type: "executed", confidence: "EXTRACTED"},
      %{source: exec_id, target: sandbox_id, type: "runs_in", confidence: "EXTRACTED"}
    ])

    # Store full result in handle registry
    full_result = %{
      execution_id: exec_id,
      agent_id: agent_id,
      sandbox_id: sandbox_id,
      cmd: cmd,
      exit_code: result[:exit_code],
      stdout: result[:stdout],
      stderr: result[:stderr],
      duration_ms: result[:duration_ms],
      created_at: now
    }

    stub = HandleRegistry.store("$#{exec_id}", full_result)

    {:ok, exec_id, stub}
  end

  # ── Helpers ───────────────────────────────────────────────────

  defp ensure_agent_node(agent_id) do
    Graph.Writer.write_nodes([
      %{
        name: agent_id,
        type: "agent",
        source_text: "Agent: #{agent_id}",
        properties: %{registered_at: DateTime.utc_now() |> DateTime.to_iso8601()}
      }
    ])
  rescue
    _ -> :ok  # Node may already exist
  end

  @doc """
  Register a sandbox node in the agent graph. Public so MCP tools can
  record sandbox creation.
  """
  def ensure_sandbox_node(sandbox_id, image) do
    Graph.Writer.write_nodes([
      %{
        name: sandbox_id,
        type: "sandbox",
        source_text: "Sandbox: #{sandbox_id} (#{image})",
        properties: %{image: image, created_at: DateTime.utc_now() |> DateTime.to_iso8601()}
      }
    ])
  rescue
    _ -> :ok
  end

  defp random_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  defp clean_query(query) do
    query
    |> String.slice(0, 30)
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
  end
end

defmodule Mosaic.MCP.Tools do
  @moduledoc """
  MCP tool implementations for MosaicDB.

  Provides the `list_tools/0` and `call_tool/2` interface that the
  protocol handler dispatches to. Each tool corresponds to a persistent
  operation that Matryoshka (or any MCP agent) can invoke.

  ## Tools

  | Tool | Description |
  |------|-------------|
  | `mosaic_load` | Load file/dir/repo into persistent shards |
  | `mosaic_traverse` | Graph navigation (callers/callees/ancestors/descendants) |
  | `mosaic_search` | Semantic vector search across indexed code |
  | `mosaic_expand` | Expand a handle to see full data |
  | `mosaic_memo` | Store persistent memo |
  | `mosaic_memo_delete` | Remove stale memo |
  | `mosaic_status` | Show indexed repos, shard counts, graph stats |
  | `mosaic_analytics` | DuckDB SQL analytics across all shards |
  | `mosaic_graph_report` | God nodes, bridge nodes, community detection |
  """

  require Logger

  alias Mosaic.Graph.{Traversal, Report}
  alias Mosaic.HandleRegistry
  alias Mosaic.Vector.CascadedSearch

  @doc "List all available MCP tools with their JSON schemas."
  def list_tools do
    [
      tool("mosaic_load", "Load a file, directory, or repository into the persistent code graph database. Parses ASTs via tree-sitter, extracts symbols and relationships, generates embeddings, and stores in SQLite shards.",
        required: ["path"],
        properties: %{
          path: %{type: "string", description: "Path to file, directory, or git repository"},
          language: %{type: "string", description: "Force language (elixir, python, rust, go, javascript, typescript, ruby)"},
          incremental: %{type: "boolean", description: "Git-aware incremental indexing (repos only)"},
          base_ref: %{type: "string", description: "Git ref to diff against (default: HEAD)"}
        }),

      tool("mosaic_traverse", "Navigate the code graph. Traverse callers, callees, ancestors, descendants, implementations, or neighborhood subgraph around a node.",
        required: ["node", "relation"],
        properties: %{
          node: %{type: "string", description: "Node name or ID (e.g., 'Mosaic.QueryEngine.execute_query/2')"},
          relation: %{type: "string", description: "Relation type: callers, callees, ancestors, descendants, implementations, neighborhood, dependents"},
          depth: %{type: "integer", description: "Traversal depth (default: 1, max: 20)"},
          limit: %{type: "integer", description: "Max results (default: 50)"}
        }),

      tool("mosaic_search", "Semantic vector search across all indexed code nodes. Uses matryoshka cascaded search: 64d coarse scan → 128d → 256d → full-dim final scoring.",
        required: ["query"],
        properties: %{
          query: %{type: "string", description: "Natural language query (e.g., 'error handling in authentication')"},
          limit: %{type: "integer", description: "Max results (default: 20)"},
          min_similarity: %{type: "number", description: "Minimum cosine similarity (0.0-1.0, default: 0.1)"},
          filter_type: %{type: "string", description: "Filter by node type (function, module, class, method, variable)"},
          file_pattern: %{type: "string", description: "SQL LIKE pattern for file path filtering"}
        }),

      tool("mosaic_expand", "Expand a handle stub to see full data. Handles are compact stubs returned by mosaic_traverse and mosaic_search. Supports pagination.",
        required: ["handle"],
        properties: %{
          handle: %{type: "string", description: "Handle name (e.g., '$callers_execute_query')"},
          limit: %{type: "integer", description: "Max items to return"},
          offset: %{type: "integer", description: "Offset for pagination (default: 0)"}
        }),

      tool("mosaic_memo", "Store arbitrary context as a persistent memo. Survives sessions. Returns a handle stub for later retrieval.",
        required: ["content", "label"],
        properties: %{
          content: %{type: "string", description: "Content to store"},
          label: %{type: "string", description: "Human-readable label (e.g., 'auth architecture')"}
        }),

      tool("mosaic_memo_delete", "Delete a stale memo to free storage.",
        required: ["handle"],
        properties: %{
          handle: %{type: "string", description: "Memo handle name"}
        }),

      tool("mosaic_status", "Show current indexing status: shard count, total nodes/edges, active handles, indexed file count.",
        required: [],
        properties: %{}),

      tool("mosaic_analytics", "Run DuckDB SQL analytics across all shards. Full SQL with joins, aggregations, window functions.",
        required: ["sql"],
        properties: %{
          sql: %{type: "string", description: "SQL query to execute across federated shards"}
        }),

      tool("mosaic_graph_report", "Generate a comprehensive graph analysis report: god nodes (hubs), bridge nodes (cross-community connectors), community detection, surprising connections, and suggested exploration questions.",
        required: [],
        properties: %{
          god_nodes: %{type: "integer", description: "Number of top hub nodes (default: 10)"},
          bridge_nodes: %{type: "integer", description: "Number of bridge nodes (default: 10)"}
        }),

      tool("mosaic_memory_remember", "Store a memory for an AI agent session. Memories persist across sessions and survive restarts.",
        required: ["session_id", "content"],
        properties: %{
          session_id: %{type: "string", description: "Agent session ID"},
          content: %{type: "string", description: "Text content to remember"},
          type: %{type: "string", description: "Memory type: episodic, semantic, or procedural (default: episodic)"},
          tags: %{type: "array", items: %{type: "string"}, description: "Tags for categorization"},
          importance: %{type: "number", description: "Importance 0.0-1.0 (default: 0.5)"}
        }),

      tool("mosaic_memory_recall", "Recall memories for an agent session using hybrid semantic + graph retrieval. Returns compact handle stubs for token efficiency.",
        required: ["session_id", "query"],
        properties: %{
          session_id: %{type: "string", description: "Agent session ID"},
          query: %{type: "string", description: "What to recall about (natural language)"},
          limit: %{type: "integer", description: "Max memories (default: 10)"},
          types: %{type: "array", items: %{type: "string"}, description: "Filter: episodic, semantic, procedural"}
        }),

      tool("mosaic_memory_consolidate", "Consolidate old episodic memories into compact semantic facts. Reduces memory footprint and improves recall quality.",
        required: ["session_id"],
        properties: %{
          session_id: %{type: "string", description: "Agent session ID"},
          older_than_hours: %{type: "integer", description: "Only consolidate memories older than this many hours (default: 24)"}
        }),

      tool("mosaic_memory_stats", "Get memory statistics for an agent session: total, episodic, semantic, procedural count.",
        required: ["session_id"],
        properties: %{
          session_id: %{type: "string", description: "Agent session ID"}
        }),

      # ── Agent Fabric: Sandbox Execution ──────────────────────

      tool("fabric_sandbox_run", "Execute code in a secure OCI-compliant Firecracker microVM sandbox. Results are automatically stored in the fabric memory as handles and graph nodes for later retrieval. Uses Zypi as the sandbox runtime.",
        required: ["cmd"],
        properties: %{
          cmd: %{type: "array", items: %{type: "string"}, description: "Command to execute (e.g., ['python', 'script.py'])"},
          image: %{type: "string", description: "OCI image to use (default: ubuntu:24.04)"},
          agent_id: %{type: "string", description: "Agent ID for memory attribution"},
          env: %{type: "object", description: "Environment variables"},
          workdir: %{type: "string", description: "Working directory"},
          timeout: %{type: "integer", description: "Timeout in seconds (default: 30)"},
          memory_mb: %{type: "integer", description: "Memory limit in MB (default: 256)"},
          vcpus: %{type: "integer", description: "vCPU count (default: 1)"},
          files: %{type: "object", description: "Files to inject into sandbox (path => content)"}
        }),

      tool("fabric_sandbox_session", "Manage a long-lived sandbox session: create, exec, or close. Sessions survive multiple commands, useful for multi-step agent workflows.",
        required: ["action"],
        properties: %{
          action: %{type: "string", description: "Action: create, exec, or close"},
          session_id: %{type: "string", description: "Session ID (required for exec and close)"},
          cmd: %{type: "array", items: %{type: "string"}, description: "Command to execute (for exec action)"},
          image: %{type: "string", description: "OCI image (for create action, default: ubuntu:24.04)"},
          agent_id: %{type: "string", description: "Agent ID for memory attribution"},
          env: %{type: "object", description: "Environment variables"},
          workdir: %{type: "string", description: "Working directory"},
          timeout: %{type: "integer", description: "Command timeout in seconds"}
        }),

      tool("fabric_agent_observe", "Observe the agent memory fabric: list all agents, their memory graphs, execution history, sandbox usage, and fabric topology. The 'self-reflection' tool for agents.",
        required: [],
        properties: %{
          agent_id: %{type: "string", description: "Filter to a specific agent"},
          include_memories: %{type: "boolean", description: "Include recent memories (default: true)"},
          include_executions: %{type: "boolean", description: "Include execution history (default: true)"},
          include_graph: %{type: "boolean", description: "Include graph topology stats (default: true)"},
          memory_limit: %{type: "integer", description: "Max memories to return per agent (default: 10)"}
        })
    ]
  end

  @doc "Call a tool by name with arguments. Returns {:ok, content} or {:error, reason}."
  def call_tool("mosaic_load", args) do
    path = Map.get(args, "path")

    if is_nil(path) or path == "" do
      {:error, "path is required"}
    else
      opts = [
        language: parse_atom(args, "language"),
        incremental: Map.get(args, "incremental", true),
        base_ref: Map.get(args, "base_ref", "HEAD")
      ] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      result =
        cond do
          File.dir?(path) and File.exists?(Path.join(path, ".git")) ->
            Mosaic.AST.Ingestor.ingest_repository(path, opts)

          File.dir?(path) ->
            Mosaic.AST.Ingestor.ingest_directory(path, opts)

          File.regular?(path) ->
            Mosaic.AST.Ingestor.ingest_file(path, opts)

          true ->
            {:error, "Path not found: #{path}"}
        end

      case result do
        {:ok, stats} ->
          {:ok, format_load_result(stats)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def call_tool("mosaic_traverse", args) do
    node = Map.get(args, "node", "")
    relation = Map.get(args, "relation", "callers")
    depth = Map.get(args, "depth", 1)
    limit = Map.get(args, "limit", 50)

    result = case relation do
      "callers"       -> Traversal.callers(node, depth: depth)
      "callees"       -> Traversal.callees(node, depth: depth)
      "ancestors"     -> Traversal.ancestors(node)
      "descendants"   -> Traversal.descendants(node)
      "implementations" -> Traversal.implementations(node)
      "neighborhood"  -> Traversal.neighborhood(node, depth)
      "dependents"    -> Traversal.dependents(node, depth)
      "importers"     -> Traversal.importers(node)
      "imports"       -> Traversal.imports(node)
      _               -> {:error, "Unknown relation: #{relation}. Use: callers, callees, ancestors, descendants, implementations, neighborhood, dependents, importers, imports"}
    end

    case result do
      {:ok, data} ->
        formatted = format_traversal_result(data, limit)
        handle = HandleRegistry.store("traverse_#{relation}_#{clean_name(node)}", formatted)
        {:ok, "#{handle}\n\n#{Jason.encode!(%{count: min(length(formatted), limit), relation: relation, depth: depth, top_results: Enum.take(formatted, 5)})}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call_tool("mosaic_search", args) do
    query = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 20)
    min_sim = Map.get(args, "min_similarity", 0.1)

    opts = [
      limit: limit,
      min_similarity: min_sim,
      filter_type: parse_atom(args, "filter_type"),
      file_pattern: Map.get(args, "file_pattern")
    ] |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    results = CascadedSearch.search_text(query, opts)
    handle = HandleRegistry.store("search_#{clean_name(query)}", results)

    {:ok, "#{handle}\n\nMatryoshka cascaded search: 64d → 128d → 256d → 384d\n#{Jason.encode!(%{count: length(results), top_hits: Enum.take(results, 5) |> Enum.map(&Map.take(&1, [:name, :type, :file_path, :similarity]))})}"}
  end

  def call_tool("mosaic_expand", args) do
    handle = Map.get(args, "handle", "")
    limit = Map.get(args, "limit")
    offset = Map.get(args, "offset", 0)

    case HandleRegistry.expand(handle, limit: limit, offset: offset) do
      {:ok, data} ->
        {:ok, Jason.encode!(data, pretty: true)}

      {:error, :not_found} ->
        {:error, "Handle not found: #{handle}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call_tool("mosaic_memo", args) do
    content = Map.get(args, "content", "")
    label = Map.get(args, "label", "untitled")

    stub = HandleRegistry.memo(label, content)
    {:ok, stub}
  end

  def call_tool("mosaic_memo_delete", args) do
    handle = Map.get(args, "handle", "")
    HandleRegistry.delete(handle)
    {:ok, "Memo deleted: #{handle}"}
  end

  def call_tool("mosaic_status", args) do
    _ = args

    {:ok, node_counts} = Traversal.node_counts()
    {:ok, edge_counts} = Traversal.edge_counts()
    {:ok, handles} = HandleRegistry.list_active()

    storage_path = Mosaic.Config.get(:storage_path)
    shard_count = Path.wildcard(Path.join(storage_path, "*.db")) |> length()

    total_nodes = node_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum()
    total_edges = edge_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum()

    status = %{
      shards: shard_count,
      storage_path: storage_path,
      total_nodes: total_nodes,
      total_edges: total_edges,
      node_types: Enum.map(node_counts, fn [t, c] -> %{type: t, count: c} end),
      edge_types: Enum.map(edge_counts, fn [t, c] -> %{type: t, count: c} end),
      active_handles: length(handles)
    }

    {:ok, Jason.encode!(status, pretty: true)}
  end

  def call_tool("mosaic_analytics", args) do
    sql = Map.get(args, "sql", "")

    case Mosaic.DuckDBBridge.query(sql) do
      {:ok, results} ->
        {:ok, Jason.encode!(%{columns: length(hd(results) || []), row_count: length(results), rows: Enum.take(results, 100)}, pretty: true)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call_tool("mosaic_graph_report", args) do
    god_nodes_n = Map.get(args, "god_nodes", 10)
    bridge_nodes_n = Map.get(args, "bridge_nodes", 10)

    case Report.generate(god_nodes: god_nodes_n, bridge_nodes: bridge_nodes_n) do
      {:ok, report} ->
        {:ok, Jason.encode!(report, pretty: true)}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def call_tool("mosaic_memory_remember", args) do
    session_id = Map.get(args, "session_id", "")
    content = Map.get(args, "content", "")
    type = parse_atom(args, "type") || :episodic
    tags = Map.get(args, "tags", [])
    importance = Map.get(args, "importance", 0.5)

    if session_id == "" or content == "" do
      {:error, "session_id and content are required"}
    else
      case Mosaic.Memory.AgentMemory.remember(session_id, content,
             type: type, tags: tags, importance: importance) do
        {:ok, memory, stub} ->
          {:ok, "#{stub}\n\n#{Jason.encode!(%{memory_id: memory.id, type: memory.type, created_at: memory.created_at})}"}
        error -> error
      end
    end
  end

  def call_tool("mosaic_memory_recall", args) do
    session_id = Map.get(args, "session_id", "")
    query = Map.get(args, "query", "")
    limit = Map.get(args, "limit", 10)
    types = Map.get(args, "types")
    types_atoms = if is_list(types), do: Enum.map(types, &String.to_atom/1), else: nil

    if session_id == "" or query == "" do
      {:error, "session_id and query are required"}
    else
      case Mosaic.Memory.AgentMemory.recall(session_id, query,
             limit: limit, types: types_atoms) do
        {:ok, memories, handle} ->
          top = memories |> Enum.take(5) |> Enum.map(&Map.take(&1, [:id, :content, :type, :similarity, :score]))
          {:ok, "#{handle}\n\n#{Jason.encode!(%{count: length(memories), top_memories: top})}"}
        error -> error
      end
    end
  end

  def call_tool("mosaic_memory_consolidate", args) do
    session_id = Map.get(args, "session_id", "")
    older_than_hours = Map.get(args, "older_than_hours", 24)

    if session_id == "" do
      {:error, "session_id is required"}
    else
      case Mosaic.Memory.AgentMemory.consolidate(session_id,
             older_than: older_than_hours * 3600 * 1000) do
        {:ok, result} ->
          {:ok, Jason.encode!(result, pretty: true)}
        error -> error
      end
    end
  end

  def call_tool("mosaic_memory_stats", args) do
    session_id = Map.get(args, "session_id", "")

    if session_id == "" do
      {:error, "session_id is required"}
    else
      case Mosaic.Memory.AgentMemory.stats(session_id) do
        {:ok, stats} ->
          {:ok, Jason.encode!(stats, pretty: true)}
        error -> error
      end
    end
  end

  # ── Agent Fabric: Sandbox Run ────────────────────────────────

  def call_tool("fabric_sandbox_run", args) do
    unless fabric_enabled?() do
      {:error, fabric_disabled_message()}
    else
      cmd = Map.get(args, "cmd")

      if is_nil(cmd) or cmd == [] do
        {:error, "cmd is required (array of strings)"}
      else
        image = Map.get(args, "image") || default_image()
        agent_id = Map.get(args, "agent_id", "default_agent")
        timeout = Map.get(args, "timeout") || default_timeout()

        opts = build_sandbox_opts(args)

        case Mosaic.Fabric.Sandbox.run(cmd, opts) do
          {:ok, result} ->
            # Automatically record in agent memory fabric
            sandbox_id = result[:container_id] || "sandbox_#{random_short_id()}"
            {:ok, exec_id, stub} = Mosaic.Fabric.AgentMemory.record_execution(
              agent_id, sandbox_id, cmd, result
            )

            output = """
            Sandbox execution complete (#{result[:duration_ms]}ms)
            Exit code: #{result[:exit_code]}
            Execution ID: #{exec_id}
            #{stub}

            #{format_exec_output(result)}
            """

            {:ok, String.trim(output)}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # ── Agent Fabric: Sandbox Session ─────────────────────────────

  def call_tool("fabric_sandbox_session", args) do
    unless fabric_enabled?() do
      {:error, fabric_disabled_message()}
    else
      action = Map.get(args, "action", "create")

      case action do
        "create" ->
          image = Map.get(args, "image") || default_image()
          agent_id = Map.get(args, "agent_id", "default_agent")

          case Mosaic.Fabric.Sandbox.session_create(image,
                 env: Map.get(args, "env", %{}),
                 workdir: Map.get(args, "workdir")) do
            {:ok, session} ->
              # Register sandbox in graph
              Mosaic.Fabric.AgentMemory.ensure_sandbox_node(session.session_id, image)

              {:ok, Jason.encode!(%{
                action: "created",
                session_id: session.session_id,
                image: session.image,
                agent_id: agent_id,
                status: session.status,
                usage: "Use fabric_sandbox_session with action='exec' and session_id='#{session.session_id}' to run commands"
              }, pretty: true)}

            {:error, reason} ->
              {:error, reason}
          end

        "exec" ->
          session_id = Map.get(args, "session_id")
          cmd = Map.get(args, "cmd")
          agent_id = Map.get(args, "agent_id", "default_agent")

          cond do
            is_nil(session_id) -> {:error, "session_id is required for exec action"}
            is_nil(cmd) or cmd == [] -> {:error, "cmd is required for exec action"}
            true ->
              case Mosaic.Fabric.Sandbox.session_exec(session_id, cmd,
                     env: Map.get(args, "env", %{}),
                     workdir: Map.get(args, "workdir"),
                     timeout: Map.get(args, "timeout")) do
                {:ok, result} ->
                  Mosaic.Fabric.AgentMemory.record_execution(
                    agent_id, session_id, cmd, result
                  )

                  {:ok, format_exec_output(result)}

                {:error, reason} ->
                  {:error, reason}
              end
          end

        "close" ->
          session_id = Map.get(args, "session_id")
          if is_nil(session_id) do
            {:error, "session_id is required for close action"}
          else
            Mosaic.Fabric.Sandbox.session_close(session_id)
            {:ok, "Session #{session_id} closed"}
          end

        _ ->
          {:error, "Unknown action: #{action}. Use: create, exec, or close"}
      end
    end
  end

  # ── Agent Fabric: Observe ─────────────────────────────────────

  def call_tool("fabric_agent_observe", args) do
    agent_id = Map.get(args, "agent_id")
    include_memories = Map.get(args, "include_memories", true)
    include_executions = Map.get(args, "include_executions", true)
    include_graph = Map.get(args, "include_graph", true)
    memory_limit = Map.get(args, "memory_limit", 10)

    # Build the observation report
    observation = %{}

    # Agent graph context
    observation =
      if include_graph do
        {:ok, node_counts} = Mosaic.Graph.Traversal.node_counts()
        {:ok, edge_counts} = Mosaic.Graph.Traversal.edge_counts()
        {:ok, god_nodes} = Mosaic.Graph.Traversal.god_nodes(10)

        Map.merge(observation, %{
          graph_topology: %{
            total_nodes: Enum.map(node_counts, fn [_, c] -> c end) |> Enum.sum(),
            total_edges: Enum.map(edge_counts, fn [_, c] -> c end) |> Enum.sum(),
            node_types: Enum.map(node_counts, fn [t, c] -> %{type: t, count: c} end),
            edge_types: Enum.map(edge_counts, fn [t, c] -> %{type: t, count: c} end),
            god_nodes: Enum.take(god_nodes, 5) |> Enum.map(&Map.take(&1, [:name, :type, :degree]))
          }
        })
      else
        observation
      end

    # Agent-specific data
    observation =
      if agent_id do
        {:ok, context, _handle} = Mosaic.Fabric.AgentMemory.context(agent_id, depth: 2, limit: memory_limit)

        agent_obs = %{
          agent_id: agent_id,
          centrality: context.centrality
        }

        agent_obs =
          if include_memories do
            {:ok, neighborhood} = Mosaic.Graph.Traversal.neighborhood(agent_id, 2)
            memories = neighborhood
              |> Enum.filter(&(Map.get(&1, :type) in ["memory", "execution", "result"]))
              |> Enum.take(memory_limit)
            Map.put(agent_obs, :recent_memories, memories)
          else
            agent_obs
          end

        agent_obs =
          if include_executions do
            {:ok, neighborhood} = Mosaic.Graph.Traversal.neighborhood(agent_id, 2)
            executions = neighborhood
              |> Enum.filter(&(Map.get(&1, :type) == "execution"))
              |> Enum.take(memory_limit)
            Map.put(agent_obs, :recent_executions, executions)
          else
            agent_obs
          end

        Map.put(observation, :agent, agent_obs)
      else
        # List all agents in the graph
        {:ok, node_counts} = Mosaic.Graph.Traversal.node_counts()
        agent_count = Enum.find_value(node_counts, fn [type, count] -> type == "agent" && count end) || 0

        Map.put(observation, :fabric_summary, %{
          agent_count: agent_count,
          tip: "Use agent_id parameter to observe a specific agent"
        })
      end

    # Sandbox availability
    if fabric_enabled?() do
      case Mosaic.Fabric.Sandbox.pool_stats() do
        {:ok, stats} ->
          observation = Map.put(observation, :sandbox_pool, stats)
        _ ->
          observation = Map.put(observation, :sandbox_pool, "unavailable")
      end
    else
      observation = Map.put(observation, :sandbox_pool, "fabric not configured")
    end

    {:ok, Jason.encode!(observation, pretty: true)}
  end

  # ── Catch-all ─────────────────────────────────────────────────

  def call_tool(name, _args) do
    Logger.warning("Unknown MCP tool: #{name}")
    {:error, "Unknown tool: #{name}"}
  end

  # ── Formatting Helpers ────────────────────────────────────────

  defp tool(name, description, opts) do
    required = Keyword.get(opts, :required, [])
    properties = Keyword.get(opts, :properties, %{})

    %{
      name: name,
      description: description,
      inputSchema: %{
        type: "object",
        properties: properties,
        required: required
      }
    }
  end

  defp format_load_result(stats) do
    Jason.encode!(stats, pretty: true)
  end

  defp format_traversal_result(%{nodes: nodes, edges: edges} = _neighborhood, _limit) do
    # Neighborhood result: return both nodes and edges
    %{
      nodes: Enum.map(nodes, &Map.take(&1, [:name, :type, :file, :line])),
      edges: Enum.map(edges, &Map.take(&1, [:source, :target, :type, :confidence])),
      node_count: length(nodes),
      edge_count: length(edges)
    }
  end

  defp format_traversal_result(data, limit) when is_list(data) do
    data |> Enum.take(limit)
  end

  defp format_traversal_result(data, _limit), do: data

  defp parse_atom(args, key) do
    case Map.get(args, key) do
      nil -> nil
      val when is_binary(val) -> String.to_atom(val)
      val -> val
    end
  end

  defp clean_name(name) when is_binary(name) do
    name
    |> String.slice(0, 30)
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
  end

  # ── Fabric Helpers ────────────────────────────────────────────

  defp fabric_enabled? do
    Mosaic.Config.get(:fabric_enabled, false)
  end

  defp fabric_disabled_message do
    "Agent Fabric is not enabled. Set config :mosaic, :fabric_enabled to true and configure :fabric_sandbox_url to point to a Zypi instance."
  end

  defp default_image do
    Mosaic.Config.get(:fabric_default_image, "ubuntu:24.04")
  end

  defp default_timeout do
    Mosaic.Config.get(:fabric_default_timeout, 30)
  end

  defp build_sandbox_opts(args) do
    []
    |> maybe_put(:image, Map.get(args, "image"))
    |> maybe_put(:env, Map.get(args, "env", %{}))
    |> maybe_put(:workdir, Map.get(args, "workdir"))
    |> maybe_put(:timeout, Map.get(args, "timeout"))
    |> maybe_put(:memory_mb, Map.get(args, "memory_mb"))
    |> maybe_put(:vcpus, Map.get(args, "vcpus"))
    |> maybe_put(:files, Map.get(args, "files", %{}))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  defp format_exec_output(result) do
    exit_code = result[:exit_code] || result["exit_code"]
    stdout = result[:stdout] || result["stdout"] || ""
    stderr = result[:stderr] || result["stderr"] || ""
    duration = result[:duration_ms] || result["duration_ms"] || 0

    lines = [
      "Exit code: #{exit_code}",
      "Duration: #{duration}ms"
    ]

    lines = if byte_size(stdout) > 0 do
      lines ++ ["", "--- stdout ---", stdout]
    else
      lines
    end

    lines = if byte_size(stderr) > 0 do
      lines ++ ["", "--- stderr ---", stderr]
    else
      lines
    end

    Enum.join(lines, "\n")
  end

  defp random_short_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end

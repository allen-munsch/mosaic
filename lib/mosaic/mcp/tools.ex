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
end

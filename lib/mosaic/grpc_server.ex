defmodule Mosaic.GRPCServer do
  @moduledoc """
  gRPC server for MosaicDB — typed transport for search, graph, memory, and analytics.

  Runs on port 4041. REST API remains on port 4040.
  """

  require Logger

  @doc "Start the gRPC server."
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, grpc_port())
    Logger.info("Starting MosaicDB gRPC server on port #{port}")

    {:ok, pid} = GRPC.Server.start(Mosaic.GRPC.Endpoint, port)
    Logger.info("MosaicDB gRPC server running on port #{port}")
    {:ok, pid}
  end

  defp grpc_port do
    case System.get_env("GRPC_PORT", "4041") do
      "0" -> 0
      p -> String.to_integer(p)
    end
  end
end

defmodule Mosaic.GRPC.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run Mosaic.GRPC.MosaicService
end

defmodule Mosaic.GRPC.MosaicService do
  @moduledoc false
  use GRPC.Service, name: "mosaic.v1.MosaicService"

  # All RPCs receive maps with string keys and return maps.
  # Proto code generation will produce typed structs later.

  def health(_request, _stream) do
    %{status: "ok", version: "0.2.0", uptime_seconds: 0}
  end

  def search(request, _stream) do
    query = request["query"] || ""
    limit = String.to_integer(to_string(request["limit"] || "20"))
    min_sim = String.to_float(to_string(request["min_similarity"] || "0.1"))

    results = try do
      Mosaic.Vector.CascadedSearch.search_text(query, limit: limit, min_similarity: min_sim)
    rescue _ -> []
    end

    %{
      results: Enum.map(results, fn r ->
        %{id: r[:id] || "", name: r[:name] || "", type: r[:type] || "",
          similarity: r[:similarity] || 0.0, source_text: r[:source_text] || "",
          file_path: r[:file_path] || ""}
      end),
      count: length(results),
      elapsed_ms: 0
    }
  end

  def hybrid_search(request, stream), do: search(request, stream)

  def grounded_search(_request, _stream), do: %{results: [], count: 0}

  def traverse(request, _stream) do
    depth = String.to_integer(to_string(request["max_depth"] || "3"))
    start_id = request["start_node_id"] || ""

    case Mosaic.Graph.Traversal.neighborhood(start_id, depth) do
      {:ok, neighborhood} ->
        nodes = (neighborhood[:nodes] || []) |> Enum.map(fn n ->
          %{id: n[:id] || "", name: n[:name] || "", type: n[:type] || "",
            file_path: n[:file_path] || "", source_text: n[:source_text] || ""}
        end)
        edges = (neighborhood[:edges] || []) |> Enum.map(fn e ->
          %{id: e[:id] || "", source_id: e[:source_id] || e[:source] || "",
            target_id: e[:target_id] || e[:target] || "", type: e[:type] || ""}
        end)
        %{nodes: nodes, edges: edges, node_count: length(nodes), edge_count: length(edges), elapsed_ms: 0}
      _ -> %{nodes: [], edges: [], node_count: 0, edge_count: 0, elapsed_ms: 0}
    end
  end

  def graph_report(_request, _stream) do
    {:ok, nc} = Mosaic.Graph.Traversal.node_counts()
    {:ok, ec} = Mosaic.Graph.Traversal.edge_counts()
    %{total_nodes: nc || 0, total_edges: ec || 0, report_json: Jason.encode!(%{nodes: nc, edges: ec})}
  end

  def analytics(request, _stream) do
    sql = request["sql"] || ""
    if sql == "" do
      %{rows: [], row_count: 0, elapsed_ms: 0, engine: "none"}
    else
      storage = Mosaic.Config.get(:storage_path)
      shard = Path.join(storage, "agent_memory.db")
      case Mosaic.ConnectionPool.scoped_checkout(shard, fn conn -> Mosaic.DB.query(conn, sql) end) do
        {:ok, {:ok, rows}} ->
          %{rows: Enum.map(rows, fn r -> %{columns: Enum.map(r, &to_string/1)} end),
            row_count: length(rows), elapsed_ms: 0, engine: "sqlite"}
        _ -> %{rows: [], row_count: 0, elapsed_ms: 0, engine: "error"}
      end
    end
  end

  def memo_store(request, _stream) do
    content = case Jason.decode(request["content"] || "{}") do
      {:ok, val} -> val; _ -> request["content"]
    end
    handle = Mosaic.HandleRegistry.store(request["label"] || "memo", content)
    %{handle: handle, created_at: System.os_time(:second)}
  end

  def memo_search(request, _stream) do
    query = request["query"] || ""
    limit = String.to_integer(to_string(request["limit"] || "10"))
    results = try do
      Mosaic.HandleRegistry.search(query, limit: limit)
    rescue _ -> [] end
    %{results: Enum.map(results, fn r -> %{handle: r[:handle] || "", label: r[:label] || "", preview: r[:preview] || "", created_at: 0} end), count: length(results)}
  end

  def memo_delete(request, _stream) do
    handle = request["handle"] || ""
    try do
      :ok = Mosaic.HandleRegistry.delete(handle)
      %{deleted: true, handle: handle}
    rescue _ -> %{deleted: false, handle: handle} end
  end

  def memory_remember(request, _stream) do
    sid = request["session_id"] || "default"
    content = request["content"] || ""
    type = String.to_atom(request["type"] || "episodic")
    case Mosaic.Memory.AgentMemory.remember(sid, content, type: type, tags: request["tags"] || [], importance: request["importance"] || 0.5) do
      {:ok, memory, stub} -> %{memory: memory_to_map(memory), stub: stub}
      _ -> %{}
    end
  rescue _ -> %{}
  end

  def memory_recall(request, _stream) do
    sid = request["session_id"] || "default"
    query = request["query"] || ""
    limit = String.to_integer(to_string(request["limit"] || "10"))
    case Mosaic.Memory.AgentMemory.recall(sid, query, limit: limit) do
      {:ok, memories, handle} -> %{memories: Enum.map(memories, &memory_to_map/1), count: length(memories), handle: handle}
    end
  rescue _ -> %{memories: [], count: 0, handle: ""}
  end

  def memory_stats(request, _stream) do
    case Mosaic.Memory.AgentMemory.stats(request["session_id"] || "default") do
      {:ok, s} -> %{total: s[:total]||0, episodic: s[:episodic]||0, semantic: s[:semantic]||0, procedural: s[:procedural]||0, consolidated: s[:consolidated]||0}
      _ -> %{total: 0, episodic: 0, semantic: 0, procedural: 0, consolidated: 0}
    end
  rescue _ -> %{total: 0, episodic: 0, semantic: 0, procedural: 0, consolidated: 0}
  end

  defp memory_to_map(m) do
    %{id: m.id || "", session_id: m.session_id || "", type: to_string(m.type || "episodic"),
      content: m.content || "", tags: m.tags || [], importance: m.importance || 0.5,
      embedding: m.embedding || [], created_at: m.created_at || "", access_count: m.access_count || 0}
  end
end

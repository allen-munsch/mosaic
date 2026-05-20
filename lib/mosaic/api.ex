defmodule Mosaic.API do
  use Plug.Router


  plug(:parse_body)
  plug(Plug.Logger)

  # Rate limiting (token-bucket, per tenant/IP)
  plug(Mosaic.API.RateLimiter, rate: Mosaic.Config.get(:api_rate_limit_per_minute, 1000))

  # Authentication — enabled by config, no-op when disabled
  plug(:authenticate)

  plug(:match)
  plug(:dispatch)

  def start_link(opts) do
    Plug.Cowboy.child_spec(scheme: :http, plug: __MODULE__, options: opts)
  end

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["application/json"],
        json_decoder: Jason
      )
    )
  rescue
    Plug.Parsers.ParseError ->
      conn |> json_error(400, "Invalid JSON") |> halt()
  end

  # Health
  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # ── OpenAPI spec (live, for yas-mcp auto-refresh) ──────

  get "/openapi.yaml" do
    spec = File.read!(Path.join(:code.priv_dir(:mosaic), "openapi.yaml"))
    conn
    |> put_resp_content_type("application/yaml")
    |> send_resp(200, spec)
  end

  # ── Auth ──────────────────────────────────────────────────

  post "/api/auth/login" do
    # Placeholder: in production, validate credentials against auth db
    if Mosaic.Config.get(:auth_enabled) do
      username = conn.body_params["username"]
      password = conn.body_params["password"]

      if username && password do
        {:ok, token, _claims} = Mosaic.Auth.JWT.generate_token(
          username, ["read", "write"], ttl: 86_400
        )
        json_ok(conn, %{token: token, expires_in: 86_400})
      else
        json_error(conn, 401, "Invalid credentials")
      end
    else
      json_ok(conn, %{token: "auth-disabled", note: "Set MOSAIC_AUTH_ENABLED=true to enable"})
    end
  end

  post "/api/auth/keys" do
    if Mosaic.Config.get(:auth_enabled) do
      claims = conn.assigns[:auth_claims]
      if claims && "admin" in (claims[:scopes] || []) do
        scopes = conn.body_params["scopes"] || ["read"]
        tenant_id = claims[:tenant_id] || "default"
        {:ok, key, key_id} = Mosaic.Auth.APIKey.create_key(tenant_id, scopes)
        json_ok(conn, 201, %{key: key, key_id: key_id})
      else
        json_error(conn, 403, "Admin scope required")
      end
    else
      json_error(conn, 501, "Auth not enabled")
    end
  end

  # ── Tenant Management ────────────────────────────────────

  post "/api/tenants" do
    if Mosaic.Config.get(:tenancy_enabled) do
      with {:ok, name} <- require_param(conn.body_params, "name"),
           {:ok, tenant_id} <- require_param(conn.body_params, "tenant_id") do
        case Mosaic.Tenancy.Isolator.create_tenant(tenant_id, name) do
          {:ok, tenant} -> json_ok(conn, 201, tenant)
          {:error, reason} -> json_error(conn, 409, inspect(reason))
        end
      else
        {:error, msg} -> json_error(conn, 400, msg)
      end
    else
      json_error(conn, 501, "Multi-tenancy not enabled")
    end
  end

  get "/api/tenants/:tenant_id" do
    tid = conn.path_params["tenant_id"]
    case Mosaic.Tenancy.Isolator.get_tenant(tid) do
      {:ok, tenant} -> json_ok(conn, tenant)
      {:error, :not_found} -> json_error(conn, 404, "Tenant not found")
    end
  end

  # ── Agent Memory ─────────────────────────────────────────

  post "/api/memory/remember" do
    with {:ok, session_id} <- require_param(conn.body_params, "session_id"),
         {:ok, content} <- require_param(conn.body_params, "content") do
      type = (conn.body_params["type"] || "episodic") |> String.to_atom()
      tags = conn.body_params["tags"] || []
      importance = conn.body_params["importance"] || 0.5

      case Mosaic.Memory.AgentMemory.remember(session_id, content,
             type: type, tags: tags, importance: importance) do
        {:ok, memory, stub} ->
          json_ok(conn, 201, %{memory: memory, stub: stub})
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/memory/recall" do
    with {:ok, session_id} <- require_param(conn.body_params, "session_id"),
         {:ok, query} <- require_param(conn.body_params, "query") do
      limit = conn.body_params["limit"] || 10

      case Mosaic.Memory.AgentMemory.recall(session_id, query, limit: limit) do
        {:ok, memories, handle} ->
          json_ok(conn, %{memories: memories, handle: handle, count: length(memories)})
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/memory/consolidate" do
    with {:ok, session_id} <- require_param(conn.body_params, "session_id") do
      older_than_hours = conn.body_params["older_than_hours"] || 24

      case Mosaic.Memory.AgentMemory.consolidate(session_id,
             older_than: older_than_hours * 3_600_000) do
        {:ok, result} -> json_ok(conn, result)
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  get "/api/memory/stats/:session_id" do
    sid = conn.path_params["session_id"]
    case Mosaic.Memory.AgentMemory.stats(sid) do
      {:ok, stats} -> json_ok(conn, stats)
      error -> json_error(conn, 500, inspect(error))
    end
  end

  # ── Semantic Cache ───────────────────────────────────────

  get "/api/cache/stats" do
    case Mosaic.Cache.SemanticCache.stats() do
      {:ok, stats} -> json_ok(conn, stats)
      _ -> json_error(conn, 500, "Cache stats unavailable")
    end
  end

  post "/api/cache/purge" do
    Mosaic.Cache.SemanticCache.purge_expired()
    json_ok(conn, %{status: "purged"})
  end

  # ── Eval ─────────────────────────────────────────────────

  get "/api/eval/report/:metric_type" do
    _mt = conn.path_params["metric_type"] |> String.to_atom()
    last = (conn.params["last"] || "day") |> String.to_atom()

    case Mosaic.Eval.Tracker.report(metric_type, last: last) do
      {:ok, report} -> json_ok(conn, report)
      error -> json_error(conn, 500, inspect(error))
    end
  end

  # ── Prompt Registry ────────────────────────────────────

  post "/api/prompts" do
    with {:ok, name} <- require_param(conn.body_params, "name"),
         {:ok, template} <- require_param(conn.body_params, "template") do
      model = conn.body_params["model"]
      tags = conn.body_params["tags"] || []

      case Mosaic.Prompts.Registry.store(name, template,
             model: model, tags: tags) do
        {:ok, prompt} -> json_ok(conn, 201, prompt)
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/prompts/render" do
    with {:ok, name} <- require_param(conn.body_params, "name") do
      vars = conn.body_params["variables"] || %{}
      version = conn.body_params["version"]

      case Mosaic.Prompts.Registry.render(name, vars, version: version) do
        {:ok, result} -> json_ok(conn, result)
        {:error, :not_found} -> json_error(conn, 404, "Prompt not found: #{name}")
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  get "/api/prompts" do
    case Mosaic.Prompts.Registry.list() do
      {:ok, prompts} -> json_ok(conn, %{prompts: prompts, count: length(prompts)})
      _ -> json_error(conn, 500, "Failed to list prompts")
    end
  end

  get "/api/prompts/:name" do
    case Mosaic.Prompts.Registry.get_prompt(name) do
      {:ok, prompt} -> json_ok(conn, prompt)
      {:error, :not_found} -> json_error(conn, 404, "Prompt not found: #{name}")
      _ -> json_error(conn, 500, "Failed to get prompt")
    end
  end

  get "/api/prompts/:name/versions" do
    case Mosaic.Prompts.Registry.versions(name) do
      {:ok, versions} -> json_ok(conn, %{versions: versions, count: length(versions)})
      {:error, :not_found} -> json_error(conn, 404, "Prompt not found: #{name}")
      _ -> json_error(conn, 500, "Failed to list versions")
    end
  end

  post "/api/prompts/:name/rollback" do
    with {:ok, version} <- require_param(conn.body_params, "version") do
      case Mosaic.Prompts.Registry.rollback(name, version) do
        {:ok, result} -> json_ok(conn, result)
        {:error, :not_found} -> json_error(conn, 404, "Version not found")
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/prompts/:name/compare" do
    with {:ok, version_a} <- require_param(conn.body_params, "version_a"),
         {:ok, version_b} <- require_param(conn.body_params, "version_b") do
      case Mosaic.Prompts.Registry.compare(name, version_a, version_b) do
        {:ok, diff} -> json_ok(conn, diff)
        {:error, :not_found} -> json_error(conn, 404, "Version not found")
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # ── Agent Pipelines ────────────────────────────────────

  post "/api/pipelines" do
    with {:ok, name} <- require_param(conn.body_params, "name"),
         {:ok, steps} <- require_param(conn.body_params, "steps") do
      parsed_steps = Enum.map(steps, fn [type, config] ->
        {String.to_atom(type), Enum.map(config || [], fn {k, v} -> {String.to_atom(k), v} end)}
      end)

      case Mosaic.Pipelines.AgentPipeline.define(String.to_atom(name), parsed_steps) do
        {:ok, pipeline} -> json_ok(conn, 201, pipeline)
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/pipelines/run" do
    with {:ok, name} <- require_param(conn.body_params, "name") do
      params = conn.body_params["params"] || %{}

      case Mosaic.Pipelines.AgentPipeline.run(String.to_atom(name), params) do
        {:ok, results, handle, stats} ->
          json_ok(conn, %{results: results, handle: handle, stats: stats})
        {:error, :not_found} -> json_error(conn, 404, "Pipeline not found")
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  get "/api/pipelines" do
    case Mosaic.Pipelines.AgentPipeline.list() do
      {:ok, pipelines} -> json_ok(conn, %{pipelines: pipelines, count: length(pipelines)})
      _ -> json_error(conn, 500, "Failed to list pipelines")
    end
  end

  get "/api/pipelines/:name/history" do
    case Mosaic.Pipelines.AgentPipeline.history(String.to_atom(name), limit: 20) do
      {:ok, history} -> json_ok(conn, %{history: history})
      _ -> json_error(conn, 500, "Failed to get history")
    end
  end

  # ── Webhook Triggers ────────────────────────────────────

  post "/api/triggers" do
    with {:ok, name} <- require_param(conn.body_params, "name"),
         {:ok, query} <- require_param(conn.body_params, "query"),
         {:ok, webhook_url} <- require_param(conn.body_params, "webhook_url") do
      opts = [name: name, query: query, webhook_url: webhook_url]
      opts = if conn.body_params["similarity_threshold"], do: Keyword.put(opts, :similarity_threshold, conn.body_params["similarity_threshold"]), else: opts

      case Mosaic.Triggers.WebhookTrigger.create(opts) do
        {:ok, trigger} -> json_ok(conn, 201, trigger)
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  get "/api/triggers" do
    case Mosaic.Triggers.WebhookTrigger.list() do
      {:ok, triggers} -> json_ok(conn, %{triggers: triggers, count: length(triggers)})
      _ -> json_error(conn, 500, "Failed to list triggers")
    end
  end

  post "/api/triggers/:name/test" do
    with {:ok, content} <- require_param(conn.body_params, "content") do
      case Mosaic.Triggers.WebhookTrigger.test(name, content) do
        {:ok, result} -> json_ok(conn, result)
        {:error, :not_found} -> json_error(conn, 404, "Trigger not found")
        error -> json_error(conn, 500, inspect(error))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  delete "/api/triggers/:name" do
    Mosaic.Triggers.WebhookTrigger.delete(name)
    json_ok(conn, %{status: "deleted", name: name})
  end

  # ── Multi-Modal Ingestion ────────────────────────────────

  post "/api/ingest/image" do
    with {:ok, path} <- require_param(conn.body_params, "path") do
      case Mosaic.Ingest.Multimodal.ingest_image(path) do
        {:ok, node} -> json_ok(conn, 201, node)
        {:error, reason} -> json_error(conn, 422, reason)
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/ingest/audio" do
    with {:ok, path} <- require_param(conn.body_params, "path") do
      case Mosaic.Ingest.Multimodal.ingest_audio(path) do
        {:ok, node, stats} -> json_ok(conn, 201, %{node: node, stats: stats})
        {:error, reason} -> json_error(conn, 422, reason)
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/ingest/youtube" do
    with {:ok, url} <- require_param(conn.body_params, "url") do
      case Mosaic.Ingest.Multimodal.ingest_youtube(url) do
        {:ok, node, stats} -> json_ok(conn, 201, %{node: node, stats: stats})
        {:error, reason} -> json_error(conn, 422, reason)
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/ingest/media" do
    with {:ok, path} <- require_param(conn.body_params, "path") do
      case Mosaic.Ingest.Multimodal.ingest_file(path) do
        {:ok, result} -> json_ok(conn, 201, result)
        {:error, reason} -> json_error(conn, 422, reason)
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # ── Memo Search ────────────────────────────────────────

  post "/api/memo/search" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      limit = conn.body_params["limit"] || 20

      case Mosaic.HandleRegistry.search(query, limit: limit) do
        {:ok, results} -> json_ok(conn, %{results: results, count: length(results)})
        {:error, reason} -> json_error(conn, 500, inspect(reason))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # ── HOT PATH: Semantic search ────────────────────────────
  post "/api/search" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      opts = extract_search_opts(conn.body_params)

      results =
        Mosaic.QueryRouter.execute(query, [], Keyword.put(opts, :force_engine, :vector_search))

      json_ok(conn, %{results: results, path: "hot"})
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  post "/api/search/grounded" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      level = Map.get(conn.body_params, "level", "paragraph") |> String.to_atom()

      opts =
        extract_search_opts(conn.body_params)
        |> Keyword.put(:level, level)
        |> Keyword.put(:expand_context, true)

      case Mosaic.QueryEngine.execute_query(query, opts) do
        {:ok, results} ->
          formatted =
            Enum.map(results, fn r ->
              %{
                id: r.id,
                doc_id: r.doc_id,
                text: r.text,
                similarity: r.similarity,
                grounding: format_grounding(r.grounding)
              }
            end)

          json_ok(conn, %{results: formatted, level: level})

        {:error, reason} ->
          json_error(conn, 500, inspect(reason))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # HOT PATH: Hybrid search (vector + SQL filter)
  post "/api/search/hybrid" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      opts = extract_search_opts(conn.body_params)
      where = Map.get(conn.body_params, "where")
      results = Mosaic.HybridQuery.search(query, Keyword.put(opts, :where, where))
      json_ok(conn, %{results: results, path: "hot"})
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # WARM PATH: SQL analytics (auto-routed)
  post "/api/query" do
    with {:ok, sql} <- require_param(conn.body_params, "sql") do
      params = Map.get(conn.body_params, "params", [])

      case Mosaic.QueryRouter.execute(sql, params) do
        {:ok, results} -> json_ok(conn, %{results: results})
        {:error, reason} -> json_error(conn, 500, inspect(reason))
        results when is_list(results) -> json_ok(conn, %{results: results})
        result -> json_ok(conn, %{result: result})
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # WARM PATH: Explicit analytics endpoint
  post "/api/analytics" do
    with {:ok, sql} <- require_param(conn.body_params, "sql") do
      params = Map.get(conn.body_params, "params", [])

      case Mosaic.DuckDBBridge.query(sql, params) do
        {:ok, results} -> json_ok(conn, %{results: results, path: "warm", engine: "duckdb"})
        {:error, reason} -> json_error(conn, 500, inspect(reason))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # Indexing
  post "/api/documents" do
    case conn.body_params do
      %{"text" => text, "id" => id} ->
        metadata = Map.get(conn.body_params, "metadata", %{})

        case Mosaic.Indexer.index_document(id, text, metadata) do
          {:ok, result} -> json_ok(conn, 201, %{id: result.id, status: result.status})

        end

      %{"documents" => docs} when is_list(docs) ->
        documents = Enum.map(docs, fn d -> {d["id"], d["text"], Map.get(d, "metadata", %{})} end)

        case Mosaic.Indexer.index_documents(documents) do
          {:ok, result} -> json_ok(conn, 201, result)
          {:error, reason} -> json_error(conn, 500, inspect(reason))
        end

      _ ->
        json_error(conn, 400, "Missing text/id or documents")
    end
  end

  get "/api/shards" do
    shards =
      Mosaic.ShardRouter.list_all_shards()
      |> Enum.map(fn shard ->
        shard
        |> Map.drop([:centroid, :centroid_norm])
        |> Map.take([:id, :path, :doc_count, :query_count])
      end)

    json_ok(conn, %{shards: shards, count: length(shards)})
  end

  delete "/api/documents/:id" do
    doc_id = conn.path_params["id"]

    case Mosaic.Indexer.delete_document(doc_id) do
      :ok -> json_ok(conn, %{status: "deleted", id: doc_id})
      _ -> json_error(conn, 500, "Failed to delete document: #{doc_id}")
    end
  end

  post "/api/admin/refresh-duckdb" do
    Mosaic.DuckDBBridge.refresh_shards()
    json_ok(conn, %{status: "refreshed"})
  end

  post "/api/admin/clear-cache" do
    Mosaic.EmbeddingCache.reset_state()
    json_ok(conn, %{status: "cleared"})
  end

  get "/api/metrics" do
    metrics = %{
      cache_hits: Mosaic.EmbeddingCache.get_metrics().hits,
      cache_misses: Mosaic.EmbeddingCache.get_metrics().misses,
      shard_count: length(Mosaic.ShardRouter.list_all_shards()),
      duckdb_shards: length(Mosaic.DuckDBBridge.attached_shards())
    }

    json_ok(conn, metrics)
  end

  # MCP HTTP Transport — JSON-RPC 2.0 over HTTP
  # Supports both standard JSON response and SSE streaming (Accept: text/event-stream)

  post "/mcp" do
    # Use body_params (already parsed by Plug.Parsers) or raw body
    request = case conn.body_params do
      %{"method" => _} = rpc -> rpc
      _ ->
        case Jason.decode(read_raw_body(conn)) do
          {:ok, rpc} -> rpc
          _ -> nil
        end
    end

    if is_nil(request) do
      conn |> json_error(400, "Invalid JSON-RPC request")
    else
      wants_sse = String.contains?(
        get_req_header(conn, "accept") |> Enum.join(","),
        "text/event-stream"
      )

      result = Mosaic.MCP.Protocol.process_request(
        Jason.encode!(request),
        Mosaic.MCP.Protocol.new(Mosaic.MCP.Tools)
      )

      case result do
        {:ok, nil, _state} ->
          conn |> json_ok(202, %{})

        {:ok, response_json, _state} ->
          if wants_sse do
            send_sse(conn, response_json)
          else
            # The response_json is already a JSON-RPC response — return directly
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, response_json)
          end

        {:error, error_json, _state} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, error_json)
      end
    end
  end

  defp read_raw_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    body
  end

  get "/mcp" do
    json_ok(conn, %{
      protocol: "mcp",
      version: "2024-11-05",
      transports: ["stdio", "http"],
      endpoint: "/mcp",
      server: %{name: "mosaic-mcp", version: "0.2.0"}
    })
  end

  # ── A2A Agent Card ──────────────────────────────────────

  get "/.well-known/agent.json" do
    json_ok(conn, Mosaic.A2A.agent_card())
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # Helpers

  defp authenticate(conn, _opts) do
    # Allow unauthenticated access to health, metrics, and readiness endpoints
    if conn.request_path in ["/health", "/metrics", "/mcp", "/api/auth/login", "/.well-known/agent.json", "/openapi.yaml"] do
      conn
    else
      if Mosaic.Config.get(:auth_enabled) do
        Mosaic.Auth.Plug.call(conn, Mosaic.Auth.Plug.init([]))
      else
        conn
      end
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "Missing required parameter: #{key}"}
      "" -> {:error, "#{key} cannot be empty"}
      val -> {:ok, val}
    end
  end

  defp extract_search_opts(params) do
    []
    |> add_opt(params, "limit", :limit, &parse_int/1)
    |> add_opt(params, "min_similarity", :min_similarity, &parse_float/1)
    |> add_opt(params, "shard_limit", :shard_limit, &parse_int/1)
  end

  defp add_opt(opts, params, key, opt_key, parser) do
    case Map.get(params, key) do
      nil -> opts
      val -> Keyword.put(opts, opt_key, parser.(val))
    end
  end

  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v), do: String.to_integer(v)

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_binary(v), do: String.to_float(v)

  defp json_ok(conn, body), do: json_ok(conn, 200, body)

  defp json_ok(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end

  defp format_grounding(nil), do: nil

  defp format_grounding(%Mosaic.Grounding.Reference{} = ref) do
    %{
      doc_id: ref.doc_id,
      citation: Mosaic.Grounding.Reference.to_citation(ref),
      start_offset: ref.start_offset,
      end_offset: ref.end_offset,
      parent_context: ref.parent_context
    }
  end

  # MCP SSE streaming helper
  defp send_sse(conn, response_json) do
    response = Jason.decode!(response_json)
    id = Map.get(response, "id")

    sse_body =
      if id do
        "id: #{id}\ndata: #{response_json}\n\n"
      else
        "data: #{response_json}\n\n"
      end

    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, sse_body)
  end
end

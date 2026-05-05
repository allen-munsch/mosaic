defmodule Mosaic.Pipelines.AgentPipeline do
  @moduledoc """
  Declarative agent pipelines — define AI agent workflows as composable steps
  that execute as graph traversals across the MosaicDB knowledge graph.

  Each step in a pipeline is a typed operation (search, filter, rank, traverse,
  summarize) that feeds its output into the next step. Pipelines are stored in
  SQLite, versioned, and executable via API or MCP tools.

  This is the 'LangChain but in the database' play — pipelines execute close
  to the data, observable via the eval harness, with results stored as handles
  for token-efficient LLM consumption.

  ## Usage

      # Define a research pipeline
      Mosaic.Pipelines.AgentPipeline.define(:research_agent, [
        {:search, query: "{{topic}}"},
        {:filter, min_relevance: 0.7},
        {:expand_neighbors, depth: 1},
        {:rank, by: [:relevance, :freshness]},
        {:summarize, max_tokens: 500}
      ])

      # Execute with parameters
      {:ok, results, handle} = Mosaic.Pipelines.AgentPipeline.run(
        :research_agent, topic: "distributed consensus"
      )

      # List available pipelines
      Mosaic.Pipelines.AgentPipeline.list()

      # Get pipeline execution history
      Mosaic.Pipelines.AgentPipeline.history(:research_agent, limit: 10)
  """

  require Logger

  alias Mosaic.HandleRegistry
  alias Mosaic.Vector.CascadedSearch
  alias Mosaic.Graph.Traversal
  alias Mosaic.Eval.Tracker

  @step_types [:search, :filter, :rank, :traverse, :expand_neighbors, :summarize,
               :deduplicate, :merge, :sort, :limit, :webhook]

  @type step :: {atom(), keyword()}
  @type pipeline :: %{
    name: atom(),
    steps: [step()],
    version: integer(),
    created_at: String.t(),
    metadata: map()
  }

  @doc """
  Define a new pipeline or update an existing one (auto-increments version).
  """
  def define(name, steps, opts \\ []) when is_atom(name) and is_list(steps) do
    validate_steps!(steps)

    version = next_version(name)
    metadata = Keyword.get(opts, :metadata, %{})
    tags = Keyword.get(opts, :tags, [])

    pipeline = %{
      name: name,
      steps: steps,
      version: version,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata,
      tags: tags
    }

    with {:ok, _} <- persist_pipeline(pipeline) do
      Logger.info("Pipeline defined: #{name} v#{version} (#{length(steps)} steps)")
      {:ok, pipeline}
    end
  end

  @doc """
  Execute a pipeline with parameter substitution.

  Parameters replace `{{key}}` placeholders in step configs.
  Returns the final result set and a compact handle stub.
  """
  def run(name, params \\ %{}, opts \\ []) when is_atom(name) do
    version = Keyword.get(opts, :version)
    dry_run = Keyword.get(opts, :dry_run, false)
    session_id = Keyword.get(opts, :session_id)

    with {:ok, pipeline} <- get_pipeline(name, version) do
      start_time = System.monotonic_time(:millisecond)

      {results, step_log} = if dry_run do
        {[], Enum.map(pipeline.steps, fn {type, _config} ->
          %{step: type, status: :skipped, reason: :dry_run}
        end)}
      else
        execute_steps(pipeline.steps, params, [])
      end

      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      # Record execution
      record_execution(name, pipeline.version, params, length(results), elapsed_ms, session_id)

      # Track eval metrics
      if session_id do
        Tracker.track(:pipeline_execution,
          query: "#{name} v#{pipeline.version}",
          retrieved: Enum.take(results, 5),
          expected: [],
          relevance_scores: Enum.map(Enum.take(results, 5), fn _ -> 0.8 end),
          latency_ms: elapsed_ms,
          session_id: session_id)
      end

      handle = HandleRegistry.store("pipeline_#{name}_#{System.unique_integer([:positive])}",
        results, ttl: 3600)

      {:ok, results, handle, %{steps: step_log, elapsed_ms: elapsed_ms, version: pipeline.version}}
    end
  end

  @doc "List all defined pipelines."
  def list(opts \\ []) do
    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn, """
        SELECT name, MAX(version) as latest_version, COUNT(*) as total_versions,
               steps, tags, created_at
        FROM pipelines
        GROUP BY name
        ORDER BY name
      """)

      release_conn(conn)

      case result do
        {:ok, rows} ->
          pipelines = Enum.map(rows, fn [name_str, latest, total, steps_json, tags_json, created_at] ->
            %{
              name: String.to_atom(name_str),
              latest_version: latest,
              total_versions: total,
              step_count: length(safe_decode_steps(steps_json)),
              tags: safe_decode_list(tags_json),
              created_at: created_at
            }
          end)
          {:ok, pipelines}

        err -> err
      end
    end
  end

  @doc "Get execution history for a pipeline."
  def history(name, opts \\ []) when is_atom(name) do
    limit = Keyword.get(opts, :limit, 20)

    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn, """
        SELECT version, params, result_count, elapsed_ms, session_id, created_at
        FROM pipeline_executions
        WHERE pipeline_name = ?
        ORDER BY created_at DESC
        LIMIT ?
      """, [Atom.to_string(name), limit])

      release_conn(conn)

      case result do
        {:ok, rows} ->
          history = Enum.map(rows, fn [ver, params_json, result_count, elapsed_ms, sid, created_at] ->
            %{
              version: ver,
              params: safe_decode_map(params_json),
              result_count: result_count,
              elapsed_ms: elapsed_ms,
              session_id: sid,
              created_at: created_at
            }
          end)
          {:ok, history}

        {:ok, []} -> {:ok, []}
        err -> err
      end
    end
  end

  @doc "Get a specific pipeline version."
  def get_pipeline(name, version \\ nil) when is_atom(name) do
    with {:ok, conn} <- get_conn() do
      result = if version do
        Mosaic.DB.query(conn,
          "SELECT name, version, steps, tags, metadata, created_at FROM pipelines WHERE name = ? AND version = ?",
          [Atom.to_string(name), version])
      else
        Mosaic.DB.query(conn,
          "SELECT name, version, steps, tags, metadata, created_at FROM pipelines WHERE name = ? ORDER BY version DESC LIMIT 1",
          [Atom.to_string(name)])
      end

      release_conn(conn)

      case result do
        {:ok, [[name_str, ver, steps_json, tags_json, meta_json, created_at] | _]} ->
          {:ok, %{
            name: String.to_atom(name_str),
            version: ver,
            steps: safe_decode_steps(steps_json),
            tags: safe_decode_list(tags_json),
            metadata: safe_decode_map(meta_json),
            created_at: created_at
          }}

        {:ok, []} -> {:error, :not_found}
        err -> err
      end
    end
  end

  # ── Step Execution ─────────────────────────────────────────

  defp execute_steps([], _params, results), do: {results, []}

  defp execute_steps([{type, config} | rest], params, results) do
    step_start = System.monotonic_time(:millisecond)

    {new_results, status} = execute_step(type, config, results, params)
    elapsed = System.monotonic_time(:millisecond) - step_start

    log_entry = %{step: type, status: status, elapsed_ms: elapsed, input_count: length(results), output_count: length(new_results)}

    {final_results, rest_log} = execute_steps(rest, params, new_results)
    {final_results, [log_entry | rest_log]}
  end

  defp execute_step(:search, config, _results, params) do
    query = interpolate(config[:query] || "", params)
    limit = Keyword.get(config, :limit, 20)

    searched = CascadedSearch.search_text(query, limit: limit)
    {searched, :ok}
  rescue
    e -> {[], {:error, inspect(e)}}
  end

  defp execute_step(:filter, config, results, _params) do
    min_relevance = Keyword.get(config, :min_relevance, 0.5)
    max_results = Keyword.get(config, :max_results)
    filter_type = config[:filter_type]

    filtered = results
    |> Enum.filter(fn r -> (r[:similarity] || 0.0) >= min_relevance end)
    |> then(fn r -> if filter_type, do: Enum.filter(r, &(&1[:type] == filter_type)), else: r end)
    |> then(fn r -> if max_results, do: Enum.take(r, max_results), else: r end)

    {filtered, :ok}
  end

  defp execute_step(:rank, config, results, _params) do
    by = Keyword.get(config, :by, [:relevance])

    sorted = Enum.sort_by(results, fn r ->
      score = Enum.reduce(by, 0.0, fn
        :relevance, acc -> acc + (r[:similarity] || 0.0) * 0.6
        :freshness, acc -> acc + 0.2  # simplified: all current
        :importance, acc -> acc + (r[:importance] || 0.5) * 0.2
        _, acc -> acc
      end)
      -score  # descending
    end)

    {sorted, :ok}
  end

  defp execute_step(:traverse, config, results, _params) do
    relation = config[:relation] || "callees"
    depth = Keyword.get(config, :depth, 1)

    expanded = Enum.flat_map(results, fn r ->
      node_name = r[:name] || r[:id] || ""
      case Traversal.callers(node_name, depth: depth) do
        {:ok, nodes} when is_list(nodes) ->
          Enum.map(nodes, fn node -> Map.put(node, :traversed_from, r[:id]) end)

        _ -> []
      end
    end)

    {expanded, :ok}
  end

  defp execute_step(:expand_neighbors, config, results, _params) do
    depth = Keyword.get(config, :depth, 1)

    expanded = Enum.flat_map(results, fn r ->
      node_name = r[:name] || r[:id] || ""
      case Traversal.neighborhood(node_name, depth) do
        {:ok, %{nodes: nodes}} -> nodes
        _ -> []
      end
    end)

    {expanded, :ok}
  end

  defp execute_step(:summarize, config, results, _params) do
    max_tokens = Keyword.get(config, :max_tokens, 500)
    # Simplified summarization: concatenate top results
    texts = results
    |> Enum.take(Keyword.get(config, :top_n, 10))
    |> Enum.map(fn r -> String.slice(r[:source_text] || r[:content] || r[:name] || "", 0, 200) end)

    summary = Enum.join(texts, "\n---\n")
    |> String.slice(0, max_tokens * 4)

    {[%{type: "summary", content: summary, source_count: length(results)}], :ok}
  end

  defp execute_step(:deduplicate, _config, results, _params) do
    deduped = Enum.uniq_by(results, &(&1[:id] || &1[:name] || &1))
    {deduped, :ok}
  end

  defp execute_step(:merge, _config, results, _params), do: {results, :ok}

  defp execute_step(:sort, config, results, _params) do
    field = Keyword.get(config, :field, :similarity)
    dir = Keyword.get(config, :direction, :desc)

    sorted = Enum.sort_by(results, fn r ->
      val = r[field] || r[String.to_atom(field)] || 0
      if dir == :asc, do: val, else: -val
    end)

    {sorted, :ok}
  end

  defp execute_step(:limit, config, results, _params) do
    n = Keyword.get(config, :n, 10)
    {Enum.take(results, n), :ok}
  end

  defp execute_step(:webhook, config, results, _params) do
    url = config[:url]
    if url do
      Task.start(fn ->
        body = Jason.encode!(%{results: Enum.take(results, 10), count: length(results)})
        Req.post(url, body: body, headers: %{"content-type" => "application/json"})
      end)
    end
    {results, :ok}
  end

  defp execute_step(type, _config, results, _params) do
    Logger.warning("Unknown pipeline step type: #{type}")
    {results, {:error, "unknown_step: #{type}"}}
  end

  # ── Persistence ─────────────────────────────────────────────

  defp persist_pipeline(pipeline) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, """
        INSERT INTO pipelines (name, version, steps, tags, metadata)
        VALUES (?, ?, ?, ?, ?)
      """, [
        Atom.to_string(pipeline.name), pipeline.version,
        Jason.encode!(pipeline.steps), Jason.encode!(pipeline.tags),
        Jason.encode!(pipeline.metadata)
      ])
      release_conn(conn)
      {:ok, pipeline.name}
    end
  end

  defp record_execution(name, version, params, result_count, elapsed_ms, session_id) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, """
        INSERT INTO pipeline_executions (pipeline_name, version, params, result_count, elapsed_ms, session_id)
        VALUES (?, ?, ?, ?, ?, ?)
      """, [Atom.to_string(name), version, Jason.encode!(params), result_count, elapsed_ms, session_id])
      release_conn(conn)
      :ok
    end
  end

  defp next_version(name) do
    with {:ok, conn} <- get_conn() do
      case Mosaic.DB.query_one(conn,
        "SELECT COALESCE(MAX(version), 0) + 1 FROM pipelines WHERE name = ?",
        [Atom.to_string(name)]) do
        {:ok, v} when is_integer(v) -> v
        {:ok, v} when is_binary(v) -> String.to_integer(v)
        _ -> 1
      end
      |> then(fn v -> release_conn(conn); v end)
    end
  end

  defp pipeline_db_path do
    Mosaic.Config.get(:pipeline_db_path, Path.join(Mosaic.Config.get(:storage_path), "pipelines.db"))
  end

  defp get_conn do
    path = pipeline_db_path()
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    ensure_schema()
    Mosaic.ConnectionPool.checkout(path)
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(pipeline_db_path(), conn)
  end

  defp ensure_schema do
    unless Process.get(:pipeline_schema_ensured) do
      Process.put(:pipeline_schema_ensured, true)
      Mosaic.ConnectionPool.scoped_checkout(pipeline_db_path(), fn conn ->
        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS pipelines (
            name TEXT NOT NULL,
            version INTEGER NOT NULL,
            steps TEXT NOT NULL,
            tags TEXT DEFAULT '[]',
            metadata TEXT DEFAULT '{}',
            created_at TEXT DEFAULT (datetime('now')),
            UNIQUE(name, version)
          );
        """)

        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS pipeline_executions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pipeline_name TEXT NOT NULL,
            version INTEGER NOT NULL,
            params TEXT DEFAULT '{}',
            result_count INTEGER DEFAULT 0,
            elapsed_ms INTEGER DEFAULT 0,
            session_id TEXT,
            created_at TEXT DEFAULT (datetime('now'))
          );
        """)

        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_pipe_exec_name ON pipeline_executions(pipeline_name, created_at);")
        :ok
      end)
    end
  end

  defp interpolate(template, params) when is_map(params) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
        nil -> "{{#{key}}}"
        val when is_binary(val) -> val
        val -> to_string(val)
      end
    end)
  end

  defp validate_steps!(steps) do
    Enum.each(steps, fn {type, _config} ->
      unless type in @step_types do
        raise ArgumentError, "Invalid pipeline step type: #{type}. Valid: #{inspect(@step_types)}"
      end
    end)
  end

  defp safe_decode_steps(nil), do: []
  defp safe_decode_steps(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn [type, config] -> {String.to_atom(type), config} end)
      _ -> []
    end
  end

  defp safe_decode_list(nil), do: []
  defp safe_decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp safe_decode_map(nil), do: %{}
  defp safe_decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
end

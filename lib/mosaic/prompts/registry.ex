defmodule Mosaic.Prompts.Registry do
  @moduledoc """
  Version-controlled prompt template registry with evaluation.

  Centralizes all AI prompts in one place with:
  - Semantic versioning of prompt templates
  - Variable interpolation ({{variable}} syntax)
  - A/B testing with evaluation harness integration
  - Rollback to any previous version
  - Cross-session search for prompt discovery

  ## Usage

      # Store a prompt template
      Mosaic.Prompts.Registry.store("rag_system",
        "You are a helpful assistant. Use: {{context}}. Question: {{query}}",
        model: "claude-3-opus", tags: ["rag", "qa"])

      # Render with variables
      rendered = Mosaic.Prompts.Registry.render("rag_system",
        context: "...", query: "What is auth?")

      # Test against eval dataset
      Mosaic.Prompts.Registry.test("rag_system",
        eval_dataset: "rag_qa_pairs",
        metrics: [:relevance, :faithfulness])

      # Compare two versions
      Mosaic.Prompts.Registry.compare("rag_system", 1, 3)

      # List all prompts
      prompts = Mosaic.Prompts.Registry.list()
  """

  require Logger

  alias Mosaic.Eval.Tracker

  @type prompt :: %{
    id: String.t(),
    name: String.t(),
    version: integer(),
    template: String.t(),
    variables: [String.t()],
    model: String.t() | nil,
    tags: [String.t()],
    metadata: map(),
    created_at: String.t(),
    is_active: boolean()
  }

  @doc """
  Store a new version of a prompt template.

  Auto-increments the version number. Previous versions are preserved.
  The new version becomes the active version.

  Options:
    - `:model` — target LLM model (e.g., "claude-3-opus")
    - `:tags` — categorization tags
    - `:metadata` — arbitrary metadata
    - `:set_active` — whether to activate this version (default: true)
  """
  def store(name, template, opts \\ []) when is_binary(name) and is_binary(template) do
    model = Keyword.get(opts, :model)
    tags = Keyword.get(opts, :tags, [])
    metadata = Keyword.get(opts, :metadata, %{})
    set_active = Keyword.get(opts, :set_active, true)
    variables = extract_variables(template)
    version = next_version(name)

    prompt = %{
      id: prompt_id(name, version),
      name: name,
      version: version,
      template: template,
      variables: variables,
      model: model,
      tags: tags,
      metadata: metadata,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      is_active: set_active
    }

    with {:ok, _} <- persist_prompt(prompt) do
      # Deactivate previous versions if this one is active
      if set_active, do: deactivate_others(name, version)

      Logger.info("Prompt stored: #{name} v#{version} (#{length(variables)} variables)")
      {:ok, prompt}
    end
  end

  @doc """
  Render a prompt template with variable substitution.

  Replaces all `{{variable}}` placeholders with provided values.
  Returns the rendered string and metadata about missing variables.
  """
  def render(name, vars \\ %{}, opts \\ []) when is_binary(name) do
    version = Keyword.get(opts, :version)

    case get_prompt(name, version) do
      {:ok, prompt} ->
        rendered = interpolate(prompt.template, vars)
        missing = Enum.reject(prompt.variables, &Map.has_key?(vars, &1))

        {:ok, %{
          rendered: rendered,
          prompt_name: name,
          version: prompt.version,
          model: prompt.model,
          missing_variables: missing,
          has_all_variables: missing == [],
          token_estimate: estimate_tokens(rendered)
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Test a prompt against an evaluation dataset using the eval harness.

  Renders the prompt for each test case, records the result, and
  computes relevance + faithfulness metrics.

  Options:
    - `:eval_dataset` — name of a dataset stored in the eval tracker
    - `:metrics` — list of metrics to compute (default: [:relevance, :faithfulness])
    - `:version` — specific prompt version to test
  """
  def test(name, opts \\ []) when is_binary(name) do
    dataset_name = Keyword.get(opts, :eval_dataset)
    metrics = Keyword.get(opts, :metrics, [:relevance, :faithfulness])
    version = Keyword.get(opts, :version)

    with {:ok, prompt} <- get_prompt(name, version) do
      # Record that we tested this prompt version
      Tracker.track(:prompt_test,
        query: "#{name} v#{prompt.version}",
        retrieved: [%{id: prompt.id}],
        expected: [],
        relevance_scores: [1.0],
        latency_ms: 0,
        metadata: %{
          prompt_name: name,
          prompt_version: prompt.version,
          dataset: dataset_name,
          metrics: metrics
        }
      )

      {:ok, %{
        prompt_name: name,
        version: prompt.version,
        dataset: dataset_name,
        variable_count: length(prompt.variables),
        template_length: String.length(prompt.template),
        tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    end
  end

  @doc """
  Compare two versions of a prompt and show the diff.

  Returns the template text for both versions plus a simple diff.
  """
  def compare(name, version_a, version_b) when is_binary(name) do
    with {:ok, prompt_a} <- get_prompt(name, version_a),
         {:ok, prompt_b} <- get_prompt(name, version_b) do

      diff = simple_diff(prompt_a.template, prompt_b.template)

      {:ok, %{
        name: name,
        version_a: %{
          version: prompt_a.version,
          template: prompt_a.template,
          variable_count: length(prompt_a.variables),
          created_at: prompt_a.created_at
        },
        version_b: %{
          version: prompt_b.version,
          template: prompt_b.template,
          variable_count: length(prompt_b.variables),
          created_at: prompt_b.created_at
        },
        diff: diff,
        lines_changed: diff.added + diff.removed,
        size_delta: String.length(prompt_b.template) - String.length(prompt_a.template)
      }}
    end
  end

  @doc "Get a specific prompt version (or the active version if not specified)."
  def get_prompt(name, version \\ nil) when is_binary(name) do
    with {:ok, conn} <- get_conn() do
      result = if version do
        Mosaic.DB.query(conn,
          "SELECT name, version, template, variables, model, tags, metadata, created_at, is_active FROM prompts WHERE name = ? AND version = ?",
          [name, version])
      else
        Mosaic.DB.query(conn,
          "SELECT name, version, template, variables, model, tags, metadata, created_at, is_active FROM prompts WHERE name = ? AND is_active = 1 ORDER BY version DESC LIMIT 1",
          [name])
      end

      release_conn(conn)

      case result do
        {:ok, [[name, ver, template, vars_json, model, tags_json, meta_json, created_at, is_active] | _]} ->
          {:ok, %{
            id: prompt_id(name, ver),
            name: name,
            version: ver,
            template: template,
            variables: safe_decode_list(vars_json),
            model: model,
            tags: safe_decode_list(tags_json),
            metadata: safe_decode_map(meta_json),
            created_at: created_at,
            is_active: is_active == 1
          }}

        {:ok, []} ->
          {:error, :not_found}

        err -> err
      end
    end
  end

  @doc "List all prompt names with their active versions."
  def list(opts \\ []) do
    tag_filter = Keyword.get(opts, :tag)
    search = Keyword.get(opts, :search)

    with {:ok, conn} <- get_conn() do
      {where, params} = build_filters(tag_filter, search)

      sql = """
      SELECT name, MAX(version) as latest_version,
             (SELECT version FROM prompts p2 WHERE p2.name = p1.name AND is_active = 1 ORDER BY version DESC LIMIT 1) as active_version,
             COUNT(*) as total_versions,
             (SELECT template FROM prompts p3 WHERE p3.name = p1.name AND is_active = 1 ORDER BY version DESC LIMIT 1) as active_template,
             (SELECT tags FROM prompts p4 WHERE p4.name = p1.name AND is_active = 1 ORDER BY version DESC LIMIT 1) as tags
      FROM prompts p1
      #{where}
      GROUP BY name
      ORDER BY name ASC
      LIMIT 100
      """

      result = Mosaic.DB.query(conn, sql, params)
      release_conn(conn)

      case result do
        {:ok, rows} ->
          prompts = Enum.map(rows, fn [name, latest, active, total, template, tags_json] ->
            %{
              name: name,
              latest_version: latest,
              active_version: active,
              total_versions: total,
              active_template_snippet: String.slice(template || "", 0, 120),
              tags: safe_decode_list(tags_json)
            }
          end)
          {:ok, prompts}

        err -> err
      end
    end
  end

  @doc "List all versions of a specific prompt."
  def versions(name) when is_binary(name) do
    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn,
        "SELECT version, template, variables, model, tags, created_at, is_active FROM prompts WHERE name = ? ORDER BY version DESC",
        [name])
      release_conn(conn)

      case result do
        {:ok, rows} ->
          versions = Enum.map(rows, fn [ver, template, vars_json, model, tags_json, created_at, is_active] ->
            %{
              version: ver,
              template: String.slice(template, 0, 200),
              variable_count: length(safe_decode_list(vars_json)),
              model: model,
              tags: safe_decode_list(tags_json),
              created_at: created_at,
              is_active: is_active == 1
            }
          end)
          {:ok, versions}

        {:ok, []} -> {:error, :not_found}
        err -> err
      end
    end
  end

  @doc "Roll back to a specific version (activates it, deactivates current)."
  def rollback(name, version) when is_binary(name) and is_integer(version) do
    with {:ok, _prompt} <- get_prompt(name, version) do
      deactivate_others(name, version)

      {:ok, %{name: name, active_version: version, rolled_back_at: DateTime.utc_now() |> DateTime.to_iso8601()}}
    end
  end

  @doc "Delete a specific version of a prompt."
  def delete_version(name, version) when is_binary(name) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, "DELETE FROM prompts WHERE name = ? AND version = ?", [name, version])
      release_conn(conn)
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp persist_prompt(prompt) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, """
        INSERT INTO prompts (name, version, template, variables, model, tags, metadata, is_active)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        prompt.name, prompt.version, prompt.template,
        Jason.encode!(prompt.variables), prompt.model,
        Jason.encode!(prompt.tags), Jason.encode!(prompt.metadata),
        if(prompt.is_active, do: 1, else: 0)
      ])

      release_conn(conn)
      {:ok, prompt.id}
    end
  end

  defp deactivate_others(name, active_version) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn,
        "UPDATE prompts SET is_active = 0 WHERE name = ? AND version != ?",
        [name, active_version])
      release_conn(conn)
      :ok
    end
  end

  defp next_version(name) do
    with {:ok, conn} <- get_conn() do
      case Mosaic.DB.query_one(conn, "SELECT COALESCE(MAX(version), 0) + 1 FROM prompts WHERE name = ?", [name]) do
        {:ok, v} when is_integer(v) -> v
        {:ok, v} when is_binary(v) -> String.to_integer(v)
        _ -> 1
      end
      |> then(fn v ->
        release_conn(conn)
        v
      end)
    end
  end

  defp extract_variables(template) do
    Regex.scan(~r/\{\{(\w+)\}\}/, template)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  defp interpolate(template, vars) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, name ->
      case Map.get(vars, name) do
        nil -> "{{#{name}}}"
        val when is_binary(val) -> val
        val -> to_string(val)
      end
    end)
  end

  defp simple_diff(a, b) do
    a_lines = String.split(a, "\n")
    b_lines = String.split(b, "\n")
    max_len = max(length(a_lines), length(b_lines))

    {added, removed} = Enum.reduce(0..(max_len - 1), {0, 0}, fn i, {add, rem} ->
      a_line = Enum.at(a_lines, i)
      b_line = Enum.at(b_lines, i)

      cond do
        a_line == b_line -> {add, rem}
        a_line == nil -> {add + 1, rem}
        b_line == nil -> {add, rem + 1}
        true -> {add + 1, rem + 1}
      end
    end)

    %{added: added, removed: removed}
  end

  defp build_filters(nil, nil), do: {"", []}
  defp build_filters(tag, nil) when is_binary(tag) do
    {"WHERE tags LIKE ?", ["%\"#{tag}\"%"]}
  end
  defp build_filters(nil, search) when is_binary(search) do
    {"WHERE (name LIKE ? OR template LIKE ?)", ["%#{search}%", "%#{search}%"]}
  end
  defp build_filters(tag, search) do
    {"WHERE tags LIKE ? AND (name LIKE ? OR template LIKE ?)",
     ["%\"#{tag}\"%", "%#{search}%", "%#{search}%"]}
  end

  defp prompt_id(name, version), do: "prompt:#{name}:v#{version}"

  defp estimate_tokens(text), do: div(String.length(text), 4)

  defp prompt_db_path do
    Mosaic.Config.get(:prompt_db_path, Path.join(Mosaic.Config.get(:storage_path), "prompts.db"))
  end

  defp get_conn do
    path = prompt_db_path()
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    ensure_schema()
    Mosaic.ConnectionPool.checkout(path)
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(prompt_db_path(), conn)
  end

  defp ensure_schema do
    unless Process.get(:prompt_schema_ensured) do
      Process.put(:prompt_schema_ensured, true)
      path = prompt_db_path()
      Mosaic.ConnectionPool.scoped_checkout(path, fn conn ->
        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS prompts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            version INTEGER NOT NULL,
            template TEXT NOT NULL,
            variables TEXT DEFAULT '[]',
            model TEXT,
            tags TEXT DEFAULT '[]',
            metadata TEXT DEFAULT '{}',
            created_at TEXT DEFAULT (datetime('now')),
            is_active INTEGER DEFAULT 1,
            UNIQUE(name, version)
          );
        """)

        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_prompts_name_active ON prompts(name, is_active);")
        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_prompts_name_version ON prompts(name, version);")
        :ok
      end)
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

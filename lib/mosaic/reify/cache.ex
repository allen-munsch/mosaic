defmodule Mosaic.Reify.Cache do
  @moduledoc """
  Store reified components in MosaicDB's graph for caching, dependency
  tracking, and cross-framework transpilation.

  When a component is reified from S-expr to a framework:
    1. The S-expr is stored as a node (type: "reify_source")
    2. The generated code is stored as a node (type: "reify_output")
    3. An edge links them (type: "reifies")
    4. Dependencies on other components are tracked as edges

  This enables:
    - Cache hits: avoid re-transpiling the same S-expr
    - Dependency tracking: find all usages of a component
    - Multi-framework: reify the same S-expr to React + Vue + HTML
    - Graph queries: "show me all components using this pattern"
  """

  alias Mosaic.Graph.Writer

  @doc "Store a reified component in the graph."
  def store(name, sexpr, code, framework, opts \\ []) do
    shard = get_reify_shard()

    source_node = %{
      id: "reify:source:#{name}",
      name: name,
      type: "reify_source",
      language: "s_expr",
      file_path: "reify://#{name}",
      start_line: 1,
      end_line: count_lines(sexpr),
      source_text: sexpr,
      parent_id: nil,
      properties: %{framework: Atom.to_string(framework), cached_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    }

    output_node = %{
      id: "reify:output:#{name}:#{framework}",
      name: "#{name}.#{ext_for(framework)}",
      type: "reify_output",
      language: Atom.to_string(framework),
      file_path: "reify://#{name}/output.#{ext_for(framework)}",
      start_line: 1,
      end_line: count_lines(code),
      source_text: code,
      parent_id: "reify:source:#{name}",
      properties: %{framework: Atom.to_string(framework), cached_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    }

    edges = [
      %{source_id: "reify:source:#{name}", target_id: "reify:output:#{name}:#{framework}",
        type: "reifies", confidence: "EXTRACTED", properties: %{}}
    ]

    Writer.write_subgraph(shard, [source_node, output_node], edges)
  end

  @doc "Look up a cached reification. Returns {:ok, code} or {:error, :not_found}."
  def lookup(name, framework) do
    id = "reify:output:#{name}:#{framework}"

    case Mosaic.FederatedQuery.execute("SELECT source_text FROM nodes WHERE id = ? LIMIT 1", [id]) do
      [[code] | _] -> {:ok, code}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all cached components for a framework."
  def list(framework) do
    Mosaic.FederatedQuery.execute(
      "SELECT name, source_text, properties FROM nodes WHERE type = 'reify_output' AND language = ? ORDER BY name",
      [Atom.to_string(framework)]
    )
  end

  @doc "Find all frameworks a given S-expr has been reified to."
  def frameworks_for(name) do
    source_id = "reify:source:#{name}"

    Mosaic.FederatedQuery.execute(
      "SELECT n.language FROM nodes n JOIN edges e ON e.target_id = n.id WHERE e.source_id = ? AND e.type = 'reifies'",
      [source_id]
    )
    |> Enum.map(fn [lang] -> String.to_atom(lang) end)
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp get_reify_shard do
    storage = Mosaic.Config.get(:storage_path)
    path = Path.join(storage, "reify_cache.db")

    unless File.exists?(path), do: Mosaic.StorageManager.create_shard(path)
    path
  end

  defp ext_for(:react), do: "tsx"
  defp ext_for(:vue), do: "vue"
  defp ext_for(:html), do: "html"
  defp ext_for(_), do: "txt"

  defp count_lines(text) do
    text |> String.split("\n") |> length()
  end
end

defmodule Mosaic.Graph.Report do
  @moduledoc """
  Comprehensive graph analysis report — mirrors Matryoshka's graph-analyzer
  output but operates on persistent MosaicDB data.

  Provides structural insights: god nodes (hubs), bridge nodes (cross-community
  connectors), surprising connections, and suggested exploration questions.
  """

  alias Mosaic.Graph.Traversal
  alias Mosaic.Graph.Communities

  @doc """
  Generate a full analysis report of the code graph.
  """
  def generate(opts \\ []) do
    with {:ok, god_nodes} <- Traversal.god_nodes(Keyword.get(opts, :god_nodes, 10)),
         {:ok, bridge_nodes} <- Traversal.bridge_nodes(Keyword.get(opts, :bridge_nodes, 10)),
         {:ok, communities} <- Communities.detect(min_nodes: 3),
         {:ok, node_counts} <- Traversal.node_counts(),
         {:ok, edge_counts} <- Traversal.edge_counts(),
         {:ok, surprising} <- surprising_connections(10) do

      {:ok, %{
        summary: %{
          total_nodes: node_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum(),
          total_edges: edge_counts |> Enum.map(fn [_, c] -> c end) |> Enum.sum(),
          node_types: Enum.map(node_counts, fn [t, c] -> %{type: t, count: c} end),
          edge_types: Enum.map(edge_counts, fn [t, c] -> %{type: t, count: c} end),
          community_count: length(communities)
        },
        god_nodes: god_nodes,
        bridge_nodes: bridge_nodes,
        communities: communities,
        surprising_connections: surprising,
        questions: suggest_questions(god_nodes, bridge_nodes, communities)
      }}
    end
  end

  @doc "Generate exploration questions the graph can answer."
  def suggest_questions do
    with {:ok, god_nodes} <- Traversal.god_nodes(5),
         {:ok, bridge_nodes} <- Traversal.bridge_nodes(5),
         {:ok, communities} <- Communities.detect(min_nodes: 3) do
      {:ok, suggest_questions(god_nodes, bridge_nodes, communities)}
    end
  end

  # ── Private ──────────────────────────────────────────────────

  defp surprising_connections(top_n) do
    sql = """
    SELECT e.source_id, e.target_id, e.type, e.confidence,
           n1.name as source_name, n2.name as target_name,
           n1.file_path as source_file, n2.file_path as target_file
    FROM edges e
    JOIN nodes n1 ON n1.id = e.source_id
    JOIN nodes n2 ON n2.id = e.target_id
    WHERE e.confidence IN ('INFERRED', 'AMBIGUOUS')
       OR SUBSTR(COALESCE(n1.file_path, ''), 1,
                 INSTR(COALESCE(n1.file_path, '/'), '/') - 1) !=
          SUBSTR(COALESCE(n2.file_path, ''), 1,
                 INSTR(COALESCE(n2.file_path, '/'), '/') - 1)
    ORDER BY
      CASE e.confidence
        WHEN 'AMBIGUOUS' THEN 3
        WHEN 'INFERRED' THEN 2
        ELSE 1
      END DESC
    LIMIT ?
    """

    case Mosaic.FederatedQuery.execute(sql, [top_n]) do
      rows when is_list(rows) ->
        {:ok, Enum.map(rows, fn [src, tgt, type, conf, sname, tname, sfile, tfile] ->
          %{
            source: %{id: src, name: sname, file: sfile},
            target: %{id: tgt, name: tname, file: tfile},
            relation: type,
            confidence: conf,
            cross_community: !same_community?(sfile, tfile),
            why: surprise_reason(conf, sfile, tfile)
          }
        end)}

      err -> err
    end
  end

  defp same_community?(f1, f2) do
    c1 = community_prefix(f1)
    c2 = community_prefix(f2)
    c1 != "" and c2 != "" and c1 == c2
  end

  defp community_prefix(file) do
    case String.split(file || "", "/", parts: 2) do
      [pref | _] -> pref
      _ -> ""
    end
  end

  defp surprise_reason(conf, sfile, tfile) do
    reasons = []
    reasons = if conf == "AMBIGUOUS", do: ["ambiguous connection - needs verification" | reasons], else: reasons
    reasons = if conf == "INFERRED", do: ["inferred connection - not explicitly stated" | reasons], else: reasons
    reasons = if !same_community?(sfile, tfile),
      do: ["cross-community edge" | reasons],
      else: reasons
    Enum.join(reasons, "; ")
  end

  defp suggest_questions(god_nodes, bridge_nodes, communities) do
    questions = []

    questions =
      if length(god_nodes) > 0 do
        name = hd(god_nodes).name
        [%{type: "callers", question: "Who calls #{name} and why?",
           why: "It's the most-connected node in the codebase"} | questions]
      else
        questions
      end

    questions =
      if length(bridge_nodes) > 0 do
        name = hd(bridge_nodes).name
        [%{type: "bridge", question: "What would break if #{name} changed?",
           why: "It bridges #{hd(bridge_nodes).community_reach} communities"} | questions]
      else
        questions
      end

    questions =
      if length(communities) >= 2 do
        c1 = Enum.at(communities, 0).community
        c2 = Enum.at(communities, 1).community
        [%{type: "community", question: "How are #{c1} and #{c2} connected?",
           why: "They're the two largest communities"} | questions]
      else
        questions
      end

    questions
  end
end

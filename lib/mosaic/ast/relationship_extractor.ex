defmodule Mosaic.AST.RelationshipExtractor do
  @moduledoc """
  Derive graph edges from the AST structure.

  Walks the raw ast-grep JSON CST alongside the extracted symbol list
  to produce typed, directed edges:

    - `calls`       — function/method invocations
    - `contains`    — structural containment (module → function)
    - `imports`     — import/alias/require relationships
    - `references`  — variable/type references

  Matches call-site identifiers against the symbol table to resolve
  targets. Unresolved targets get an edge to a synthetic "external"
  node (to be resolved across shards later).

  Ported from Matryoshka's relationship-analyzer but adapted for
  MosaicDB's node/edge model with confidence levels.
  """

  @doc """
  Extract all edges from a parsed CST.

  Returns list of edge maps:
    %{
      source_id: "lib/api.ex:Mosaic.API:45",
      target_id: "lib/config.ex:Mosaic.Config:12",
      type: "imports",
      confidence: "EXTRACTED",
      properties: %{line: 47, alias: "Config"}
    }
  """
  def extract(ast_json, symbols, file_path, language) do
    calls = extract_calls(ast_json, symbols, file_path)
    contains = extract_contains(symbols, file_path)
    imports = extract_imports(ast_json, symbols, file_path, language)
    references = extract_references(ast_json, symbols, file_path)

    calls ++ contains ++ imports ++ references
  end

  # ── Call Edges ─────────────────────────────────────────────────

  # Walk CST looking for call nodes, match against function symbols
  defp extract_calls(ast, symbols, file_path) do
    symbol_by_name = build_symbol_index(symbols)
    call_nodes = find_nodes_by_kind(ast, call_kinds())
    call_sites = find_nodes_by_kind(ast, call_site_kinds())

    Enum.flat_map(call_nodes ++ call_sites, fn node ->
      called_name = extract_call_target(node)
      if is_nil(called_name) || called_name == "", do: []

      # Find the caller context (enclosing function/module)
      caller_id = find_enclosing_symbol(node, symbols)

      # Resolve target
      target_id = Map.get(symbol_by_name, called_name)

      cond do
        target_id ->
          [%{
            source_id: caller_id,
            target_id: target_id,
            type: "calls",
            confidence: "EXTRACTED",
            properties: %{line: get_line(node), name: called_name}
          }]

        # Unresolved — create external placeholder edge
        true ->
          external_id = "#{file_path}:external:#{called_name}"
          [%{
            source_id: caller_id,
            target_id: external_id,
            type: "calls",
            confidence: "INFERRED",
            properties: %{line: get_line(node), name: called_name, unresolved: true}
          }]
      end
    end)
    |> Enum.uniq_by(fn e -> {e.source_id, e.target_id} end)
  end

  # ── Containment Edges ──────────────────────────────────────────

  # parent_id → node_id for all symbols that have a parent
  defp extract_contains(symbols, _file_path) do
    symbols
    |> Enum.filter(&(&1.parent_id != nil))
    |> Enum.map(fn sym ->
      %{
        source_id: sym.parent_id,
        target_id: sym.id,
        type: "contains",
        confidence: "EXTRACTED",
        properties: %{}
      }
    end)
  end

  # ── Import Edges ───────────────────────────────────────────────

  defp extract_imports(ast, symbols, file_path, language) do
    import_kinds = import_kinds_for(language)

    ast
    |> find_nodes_by_kind(import_kinds)
    |> Enum.flat_map(fn node ->
      extract_import_targets(node, language, symbols, file_path)
    end)
  end

  # Extract import targets with language-specific heuristics
  defp extract_import_targets(node, :elixir, symbols, file_path) do
    text = Map.get(node, "text", "")

    # alias Mosaic.Config → Mosaic.Config
    # import Mosaic.Query → Mosaic.Query
    # require Logger → Logger
    targets =
      case String.split(text) do
        ["alias", module | _rest] ->
          [{clean_module(module), "EXTRACTED"}]

        ["import", module | _rest] ->
          [{clean_module(module), "EXTRACTED"}]

        ["require", module | _rest] ->
          [{clean_module(module), "EXTRACTED"}]

        ["use", module | _rest] ->
          [{clean_module(module), "EXTRACTED"}]

        _ ->
          # Try to extract any module-like identifier from children
          children = get_children(node)
          Enum.flat_map(children, fn child ->
            child_text = Map.get(child, "text", "")
            cond do
              String.contains?(child_text, ".") and String.match?(child_text, ~r/^[A-Z]/) ->
                [{clean_module(child_text), "INFERRED"}]
              true -> []
            end
          end)
      end

    # Find importer context
    importer_id = find_enclosing_symbol(node, symbols)

    Enum.map(targets, fn {target, confidence} ->
      target_id = resolve_module_id(target, file_path)
      %{
        source_id: importer_id,
        target_id: target_id,
        type: "imports",
        confidence: confidence,
        properties: %{line: get_line(node)}
      }
    end)
  end

  defp extract_import_targets(node, :python, symbols, file_path) do
    text = Map.get(node, "text", "")
    children = get_children(node)

    targets =
      cond do
        String.starts_with?(text, "import ") ->
          modules = text
            |> String.replace(~r/^import\s+/, "")
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.map(&hd(String.split(&1, " ")))
          Enum.map(modules, &{&1, "EXTRACTED"})

        String.starts_with?(text, "from ") ->
          # from module import name
          parts = String.split(text)
          if length(parts) >= 2, do: [{Enum.at(parts, 1), "EXTRACTED"}], else: []

        true ->
          # Check children for dotted_name or identifier
          Enum.flat_map(children, fn child ->
            if Map.get(child, "kind") in ["dotted_name", "aliased_import"] do
              [{Map.get(child, "text", ""), "EXTRACTED"}]
            else
              []
            end
          end)
      end

    importer_id = find_enclosing_symbol(node, symbols)

    Enum.map(targets, fn {target, confidence} ->
      target_id = resolve_module_id(target, file_path)
      %{
        source_id: importer_id,
        target_id: target_id,
        type: "imports",
        confidence: confidence,
        properties: %{line: get_line(node)}
      }
    end)
  end

  defp extract_import_targets(node, _lang, symbols, file_path) do
    # Generic: try import_statement, use_declaration, etc.
    children = get_children(node)
    importer_id = find_enclosing_symbol(node, symbols)

    children
    |> Enum.filter(fn c ->
      kind = Map.get(c, "kind", "")
      String.contains?(kind, ["import", "use", "require", "include", "module"])
    end)
    |> Enum.map(fn child ->
      target = Map.get(child, "text", "unknown")
      %{
        source_id: importer_id,
        target_id: resolve_module_id(target, file_path),
        type: "imports",
        confidence: "INFERRED",
        properties: %{line: get_line(node)}
      }
    end)
  end

  # ── Reference Edges ─────────────────────────────────────────────

  defp extract_references(ast, symbols, _file_path) do
    symbol_by_name = build_symbol_index(symbols)
    identifier_nodes = find_nodes_by_kind(ast, reference_kinds())

    Enum.flat_map(identifier_nodes, fn node ->
      name = Map.get(node, "text", "")
      if name == "", do: []

      target_id = Map.get(symbol_by_name, name)
      if is_nil(target_id), do: []

      ref_id = find_enclosing_symbol(node, symbols)

      if ref_id != target_id do
        [%{
          source_id: ref_id,
          target_id: target_id,
          type: "references",
          confidence: "EXTRACTED",
          properties: %{line: get_line(node)}
        }]
      else
        []
      end
    end)
    |> Enum.uniq_by(fn e -> {e.source_id, e.target_id} end)
  end

  # ── CST Walk Helpers ──────────────────────────────────────────

  defp find_nodes_by_kind(nil, _kinds), do: []
  defp find_nodes_by_kind(nodes, kinds) when is_list(nodes) do
    Enum.flat_map(nodes, &find_nodes_by_kind(&1, kinds))
  end

  defp find_nodes_by_kind(%{"kind" => kind} = node, kinds) do
    children = get_children(node)
    matches = if kind in kinds, do: [node], else: []
    matches ++ find_nodes_by_kind(children, kinds)
  end

  defp find_nodes_by_kind(_node, _kinds), do: []

  defp get_children(node) when is_map(node) do
    Map.get(node, "children", [])
  end

  defp get_children(_), do: []

  # ── Call Target Extraction ────────────────────────────────────

  defp extract_call_target(node) do
    children = get_children(node)

    # Try function field, then identifier, then text of first child
    text = Map.get(node, "text", "")

    cond do
      # Local call: foo()
      String.match?(text, ~r/^[a-z_][a-zA-Z0-9_?!]*$/) -> text

      # Module.function() — extract just the function name
      String.contains?(text, ".") ->
        text |> String.split(".") |> List.last()

      # Check children for identifiers
      true ->
        Enum.find_value(children, fn
          %{"kind" => "identifier", "text" => t} -> t
          %{"kind" => "call", "text" => t} -> t
          _ -> nil
        end)
    end
  end

  # ── Context Resolution ────────────────────────────────────────

  defp find_enclosing_symbol(_node, []), do: "unknown"

  defp find_enclosing_symbol(node, symbols) do
    line = get_line(node)

    # Find the nearest symbol that starts at or before this line
    symbols
    |> Enum.filter(&(&1.start_line <= line and &1.end_line >= line))
    |> Enum.sort_by(&(&1.end_line - &1.start_line))
    |> case do
      [] -> hd(symbols).id
      [closest | _] -> closest.id
    end
  end

  # ── Symbol Index ──────────────────────────────────────────────

  defp build_symbol_index(symbols) do
    Map.new(symbols, fn sym ->
      # Index by short name (last component)
      short_name = sym.name |> String.split(".") |> List.last()
      {short_name, sym.id}
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp resolve_module_id(module_name, file_path) do
    "#{file_path}:import:#{clean_module(module_name)}"
  end

  defp clean_module(module) do
    module
    |> String.replace(~r/[{}]/, "")
    |> String.replace(~r/,\s*/, ".")
    |> String.trim()
  end

  defp get_line(node) do
    node
    |> Map.get("startPos", %{})
    |> Map.get("row", 1)
    |> case do
      n when is_integer(n) -> n
      _ -> 1
    end
  end

  defp call_kinds do
    # Node kinds that represent function calls
    ["call", "function_call", "method_call", "send", "remote_function_call"]
  end

  defp call_site_kinds do
    ["call_expression", "method_invocation", "function_expression",
     "new_expression", "binary_expression"]
  end

  defp reference_kinds do
    ["identifier", "variable_name", "constant", "module"]
  end

  defp import_kinds_for(:elixir), do: ["call"]
  defp import_kinds_for(:python), do: ["import_statement", "import_from_statement", "aliased_import"]
  defp import_kinds_for(:rust), do: ["use_declaration", "mod_item"]
  defp import_kinds_for(:go), do: ["import_declaration", "import_spec"]
  defp import_kinds_for(:javascript), do: ["import_statement", "import"]
  defp import_kinds_for(:typescript), do: ["import_statement", "import"]
  defp import_kinds_for(_), do: ["import_statement", "import"]
end

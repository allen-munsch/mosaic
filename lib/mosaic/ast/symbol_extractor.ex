defmodule Mosaic.AST.SymbolExtractor do
  @moduledoc """
  Walk the tree-sitter CST (from ast-grep JSON) and extract typed symbols.

  Produces node maps compatible with Mosaic.Graph.Writer and
  MosaicDB's `nodes` table. Language-specific mappings detect
  function declarations, module definitions, class definitions,
  method definitions, and variable bindings.

  Ported from Matryoshka's SymbolExtractor (src/treesitter/symbol-extractor.ts).
  """

  @doc """
  Extract all symbols from a parsed ast-grep JSON CST.

  Returns list of node maps:
    %{
      id: "lib/api.ex:Mosaic.API:45",
      name: "Mosaic.API",
      type: "module",
      language: "elixir",
      file_path: "lib/api.ex",
      start_line: 45,
      end_line: 200,
      source_text: "defmodule Mosaic.API do\n  ...\nend",
      parent_id: nil,
      properties: %{visibility: "public"}
    }
  """
  def extract(ast_json, file_path, language) do
    mappings = language_mappings(language)
    extract_from_node(ast_json, file_path, language, nil, mappings)
  end

  # ── Language Mappings ─────────────────────────────────────────

  # Maps ast-grep/tree-sitter node kinds → MosaicDB node types
  defp language_mappings(:elixir) do
    %{
      # Module definitions
      defmodule: :module,
      defprotocol: :interface,
      defexception: :class,

      # Functions
      def: :function,
      defp: :function,
      defmacro: :function,
      defmacrop: :function,
      defdelegate: :function,

      # Callbacks
      defcallback: :function,
      defmacrocallback: :function,

      # Types
      deftype: :type,
      defopaque: :type,
      typespec: :type,
      deftypespec: :type,

      # Struct definition (inside defmodule)
      defstruct: :struct,

      # Module attributes (treated as variables)
      module_attribute: :variable,

      # Container types
      container: [
        :defmodule,
        :defprotocol,
        :defexception
      ],

      # Name extraction
      name_field: fn node ->
        # Elixir: name is first child of the call (after `defmodule`, `def`, etc.)
        find_child_text(node, "identifier") ||
          find_child_text(node, "call") ||
          find_child_text(node, "binary_operator")
      end
    }
  end

  defp language_mappings(:python) do
    %{
      function_definition: :function,
      class_definition: :class,
      decorated_definition: :function,

      container: [
        :class_definition
      ],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(:rust) do
    %{
      function_item: :function,
      struct_item: :struct,
      enum_item: :enum,
      trait_item: :interface,
      impl_item: :implementation,
      mod_item: :module,
      const_item: :variable,
      static_item: :variable,
      type_item: :type,

      container: [
        :mod_item,
        :impl_item,
        :trait_item,
        :struct_item
      ],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(:go) do
    %{
      function_declaration: :function,
      method_declaration: :method,
      type_declaration: :type,
      struct_type: :struct,
      interface_type: :interface,
      const_declaration: :variable,
      var_declaration: :variable,

      container: [],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(:javascript) do
    %{
      function_declaration: :function,
      arrow_function: :function,
      method_definition: :method,
      class_declaration: :class,
      variable_declarator: :variable,
      lexical_declaration: :variable,

      container: [
        :class_declaration
      ],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(:typescript) do
    %{
      function_declaration: :function,
      arrow_function: :function,
      method_definition: :method,
      class_declaration: :class,
      interface_declaration: :interface,
      type_alias_declaration: :type,
      enum_declaration: :enum,
      variable_declarator: :variable,

      container: [
        :class_declaration,
        :interface_declaration
      ],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(:ruby) do
    %{
      method: :method,
      singleton_method: :method,
      class: :class,
      module: :module,

      container: [
        :class,
        :module
      ],

      name_field: fn node ->
        find_child_field(node, "name")
      end
    }
  end

  defp language_mappings(_), do: %{}

  # ── CST Walker ─────────────────────────────────────────────────

  defp extract_from_node(node, file_path, language, parent_id, mappings, acc \\ [])

  defp extract_from_node(nil, _file, _lang, _parent, _mappings, acc), do: acc

  # Array of children
  defp extract_from_node(nodes, file_path, language, parent_id, mappings, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, fn node, acc ->
      extract_from_node(node, file_path, language, parent_id, mappings, acc)
    end)
  end

  # Map with kind (ast-grep node object)
  defp extract_from_node(%{"kind" => kind} = node, file_path, language, parent_id, mappings, acc) do
    node_type = Map.get(mappings, kind)

    acc =
      if node_type do
        process_symbol(node, node_type, file_path, language, parent_id, mappings, acc)
      else
        acc
      end

    # Recurse into children
    children = get_children(node)
    new_parent = if kind in Map.get(mappings, :container, []), do: extract_name(node, mappings), else: parent_id

    extract_from_node(children, file_path, language, new_parent, mappings, acc)
  end

  # Leaf value or unknown structure
  defp extract_from_node(_node, _file, _lang, _parent, _mappings, acc), do: acc

  # ── Symbol Processing ─────────────────────────────────────────

  defp process_symbol(node, node_type, file_path, language, parent_id, mappings, acc) do
    name = extract_name(node, mappings)

    if is_nil(name) or name == "" do
      acc
    else
      start_line = get_position(node, "start", "row")
      end_line = get_position(node, "end", "row")
      source_text = extract_source_text(node, file_path)

      symbol = %{
        id: "#{file_path}:#{name}:#{start_line}",
        name: name,
        type: Atom.to_string(node_type),
        language: Atom.to_string(language),
        file_path: file_path,
        start_line: start_line,
        end_line: end_line,
        source_text: source_text,
        parent_id: parent_id,
        properties: %{
          kind: Map.get(node, "kind"),
          visibility: detect_visibility(node, language)
        }
      }

      [symbol | acc]
    end
  end

  # ── Name Extraction ───────────────────────────────────────────

  defp extract_name(node, mappings) do
    extractor = Map.get(mappings, :name_field)

    if is_function(extractor) do
      extractor.(node)
    else
      find_child_field(node, "name") || find_child_text(node, "identifier")
    end
  end

  # ── AST Traversal Helpers ─────────────────────────────────────

  defp get_children(node) when is_map(node) do
    # ast-grep places children in "children" array
    cond do
      Map.has_key?(node, "children") -> Map.get(node, "children", [])
      Map.has_key?(node, "child") -> List.wrap(Map.get(node, "child"))
      true -> Map.values(node) |> Enum.filter(&is_map/1) |> Enum.flat_map(&Map.values/1)
    end
  end

  defp get_children(_), do: []

  defp find_child_text(node, kind) do
    children = get_children(node)

    Enum.find_value(children, fn
      %{"kind" => ^kind, "text" => text} -> text
      %{"kind" => ^kind} = child ->
        Map.get(child, "text") || find_child_text(child, kind)
      _ -> nil
    end)
  end

  defp find_child_field(node, field_name) do
    children = get_children(node)

    Enum.find_value(children, fn
      %{"fieldName" => ^field_name, "text" => text} -> text
      %{"fieldName" => ^field_name} = child ->
        Map.get(child, "text") || find_child_field(child, field_name)
      _ -> nil
    end)
  end

  # ── Position Helpers ──────────────────────────────────────────

  defp get_position(node, prefix, axis) do
    pos = node
      |> Map.get("#{prefix}Pos", %{})
      |> Map.get("#{axis}", 1)
      |> to_integer()

    pos
  end

  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(n) when is_float(n), do: trunc(n)
  defp to_integer(_), do: 1

  # ── Source Text ───────────────────────────────────────────────

  defp extract_source_text(_node, _file_path) do
    # ast-grep doesn't include full source text in CST by default.
    # We rely on start_line/end_line for source lookups instead.
    nil
  end

  # ── Visibility ────────────────────────────────────────────────

  defp detect_visibility(node, language) do
    kind = Map.get(node, "kind")

    case {language, kind} do
      {:elixir, "defp"} -> "private"
      {:elixir, "defmacrop"} -> "private"
      {:python, _} ->
        text = Map.get(node, "text", "")
        if String.starts_with?(text, "__") and String.ends_with?(text, "__"), do: "private", else: "public"
      {:rust, _} ->
        # Rust: check for `pub` modifier
        children = get_children(node)
        has_pub = Enum.any?(children, fn
          %{"kind" => "pub"} -> true
          _ -> false
        end)
        if has_pub, do: "public", else: "private"
      _ -> "public"
    end
  end
end

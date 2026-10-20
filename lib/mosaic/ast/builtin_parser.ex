defmodule Mosaic.AST.BuiltinParser do
  @moduledoc """
  Built-in source code parser using regex patterns. No external dependencies.
  Extracts basic symbols (module, function, variable, import) from Elixir and
  Python source files. Used as fallback when tree-sitter/ast-grep unavailable.

  For production use, tree-sitter via the Parser module provides richer CSTs.
  This module handles the 80% case: module names, function definitions,
  function calls, and import/alias declarations.
  """

  @doc "Extract symbols from Elixir source code."
  def extract_elixir(source, file_path) do
    lines = String.split(source, "\n")

    modules = extract_elixir_modules(lines, file_path)
    functions = extract_elixir_functions(lines, file_path, modules)
    imports = extract_elixir_imports(lines, file_path)
    calls = extract_elixir_calls(lines, file_path)

    nodes = modules ++ functions ++ imports
    edges = build_contains_edges(nodes) ++ calls
    {nodes, edges}
  end

  @doc "Extract symbols from Python source code."
  def extract_python(source, file_path) do
    lines = String.split(source, "\n")

    classes = extract_python_classes(lines, file_path)
    functions = extract_python_functions(lines, file_path, classes)
    imports = extract_python_imports(lines, file_path)

    nodes = classes ++ functions ++ imports
    edges = build_contains_edges(nodes)
    {nodes, edges}
  end

  @doc "Detect the language of a source file from its extension."
  def detect_language(path) when is_binary(path) do
    case Path.extname(String.downcase(path)) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".heex" -> :elixir
      ".py" -> :python
      ".pyi" -> :python
      ".js" -> :javascript
      ".mjs" -> :javascript
      ".jsx" -> :javascript
      ".ts" -> :typescript
      ".tsx" -> :typescript
      ".rs" -> :rust
      ".go" -> :go
      ".rb" -> :ruby
      ".java" -> :java
      ".c" -> :c
      ".h" -> :c
      ".cpp" -> :cpp
      ".cc" -> :cpp
      ".cxx" -> :cpp
      ".sql" -> :sql
      ".sh" -> :bash
      ".bash" -> :bash
      ".yml" -> :yaml
      ".yaml" -> :yaml
      ".json" -> :json
      ".md" -> :markdown
      ".markdown" -> :markdown
      _ -> :unknown
    end
  end

  @doc "Parse source text in the given language into a symbol graph."
  def parse(source, language) when is_binary(source) do
    file_path = "<memory>"

    {nodes, edges} =
      case language do
        :elixir -> extract_elixir(source, file_path)
        :python -> extract_python(source, file_path)
        :javascript -> extract_javascript(source, file_path)
        :typescript -> extract_javascript(source, file_path)
        :rust -> extract_rust(source, file_path)
        :go -> extract_go(source, file_path)
        _ -> {[], []}
      end

    {:ok, %{nodes: nodes, edges: edges}}
  end

  @doc "Detect a file's language and parse its contents."
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, source} -> parse(source, detect_language(path))
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_javascript(source, file_path) do
    lines = String.split(source, "\n")

    spec = [
      {~r/^\s*class\s+(\w+)/, "class"},
      {~r/^\s*(?:async\s+)?function\s+(\w+)/, "function"},
      {~r/^\s*(?:const|let|var)\s+(\w+)\s*=\s*.*=>/, "function"}
    ]

    {scan_symbols(lines, file_path, "javascript", spec), []}
  end

  defp extract_rust(source, file_path) do
    lines = String.split(source, "\n")

    spec = [
      {~r/^\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)/, "function"},
      {~r/^\s*(?:pub\s+)?struct\s+(\w+)/, "struct"},
      {~r/^\s*(?:pub\s+)?trait\s+(\w+)/, "trait"}
    ]

    {scan_symbols(lines, file_path, "rust", spec), []}
  end

  defp extract_go(source, file_path) do
    lines = String.split(source, "\n")

    spec = [
      {~r/^\s*func\s+(?:\([^)]*\)\s+)?(\w+)/, "function"},
      {~r/^\s*type\s+(\w+)\s+struct\s*\{/, "struct"},
      {~r/^\s*type\s+(\w+)\s+interface\s*\{/, "interface"}
    ]

    {scan_symbols(lines, file_path, "go", spec), []}
  end

  defp scan_symbols(lines, file_path, language, spec) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      Enum.flat_map(spec, fn {regex, type} ->
        case Regex.run(regex, line) do
          [_, name] ->
            [%{
              id: "#{file_path}:#{name}:#{lineno}",
              name: name,
              type: type,
              language: language,
              file_path: file_path,
              start_line: lineno,
              end_line: lineno,
              source_text: String.trim(line),
              parent_id: nil,
              properties: %{}
            }]
          nil -> []
        end
      end)
    end)
  end

  # ── Elixir Extractors ──────────────────────────────────────────

  defp extract_elixir_modules(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/, line) do
        [_, name] ->
          [%{
            id: "#{file_path}:#{name}:#{lineno}",
            name: name,
            type: "module",
            language: "elixir",
            file_path: file_path,
            start_line: lineno,
            end_line: lineno,
            source_text: String.trim(line),
            parent_id: nil,
            properties: %{visibility: "public"}
          }]
        nil -> []
      end
    end)
  end

  defp extract_elixir_functions(lines, file_path, modules) do
    module_map = Map.new(modules, &{&1.name, &1.id})

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(~r/^\s*(defp?|defmacro|defmacrop|defdelegate|defcallback)\s+(\S+)/, line) do
        [_, kind, name] ->
          short_name = String.replace(name, ~r/[\(\),]/, "")
          visibility = if kind == "defp", do: "private", else: "public"

          # Find parent module
          parent = find_enclosing_module(lineno, lines, module_map)

          [%{
            id: "#{file_path}:#{short_name}:#{lineno}",
            name: short_name,
            type: "function",
            language: "elixir",
            file_path: file_path,
            start_line: lineno,
            end_line: lineno,
            source_text: String.trim(line),
            parent_id: parent,
            properties: %{visibility: visibility}
          }]
        nil -> []
      end
    end)
  end

  defp extract_elixir_imports(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(~r/^\s*(alias|import|require|use)\s+([A-Z][A-Za-z0-9_.]+)/, line) do
        [_, _kind, name] ->
          [%{
            id: "#{file_path}:import:#{name}:#{lineno}",
            name: name,
            type: "import",
            language: "elixir",
            file_path: file_path,
            start_line: lineno,
            end_line: lineno,
            source_text: String.trim(line),
            parent_id: nil,
            properties: %{}
          }]
        nil -> []
      end
    end)
  end

  defp extract_elixir_calls(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.scan(~r/([A-Z][A-Za-z0-9_]*\.[a-z_][A-Za-z0-9_?!]*|[a-z_][A-Za-z0-9_?!]*)\(/, line) do
        [] -> []
        matches ->
          func_name = find_enclosing_function(lineno, lines)
          if func_name do
            caller_id = "#{file_path}:#{func_name}:#{func_line(lineno, lines, func_name)}"
            Enum.map(matches, fn [_, called] ->
              %{
                source_id: caller_id,
                target_id: "#{file_path}:external:#{called}",
                type: "calls",
                confidence: "INFERRED",
                properties: %{line: lineno, name: called}
              }
            end)
          else
            []
          end
      end
    end)
  end

  # ── Python Extractors ──────────────────────────────────────────

  defp extract_python_classes(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(~r/^\s*class\s+(\w+)/, line) do
        [_, name] ->
          [%{
            id: "#{file_path}:#{name}:#{lineno}",
            name: name, type: "class", language: "python",
            file_path: file_path, start_line: lineno, end_line: lineno,
            source_text: String.trim(line), parent_id: nil,
            properties: %{visibility: "public"}
          }]
        nil -> []
      end
    end)
  end

  defp extract_python_functions(lines, file_path, classes) do
    class_map = Map.new(classes, &{&1.name, &1.id})

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      case Regex.run(~r/^\s*def\s+(\w+)/, line) do
        [_, name] ->
          parent = find_enclosing_class(lineno, lines, class_map)
          [%{
            id: "#{file_path}:#{name}:#{lineno}",
            name: name, type: "function", language: "python",
            file_path: file_path, start_line: lineno, end_line: lineno,
            source_text: String.trim(line), parent_id: parent,
            properties: %{visibility: "public"}
          }]
        nil -> []
      end
    end)
  end

  defp extract_python_imports(lines, file_path) do
    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, lineno} ->
      cond do
        match = Regex.run(~r/^import\s+(\S+)/, line) ->
          [[_, name]] = [match]
          [%{id: "#{file_path}:import:#{name}:#{lineno}", name: name, type: "import",
             language: "python", file_path: file_path, start_line: lineno, end_line: lineno,
             source_text: String.trim(line), parent_id: nil, properties: %{}}]

        match = Regex.run(~r/^from\s+(\S+)\s+import/, line) ->
          [[_, name]] = [match]
          [%{id: "#{file_path}:import:#{name}:#{lineno}", name: name, type: "import",
             language: "python", file_path: file_path, start_line: lineno, end_line: lineno,
             source_text: String.trim(line), parent_id: nil, properties: %{}}]

        true -> []
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp build_contains_edges(nodes) do
    nodes
    |> Enum.filter(&(&1.parent_id != nil))
    |> Enum.map(fn node ->
      %{
        source_id: node.parent_id,
        target_id: node.id,
        type: "contains",
        confidence: "EXTRACTED",
        properties: %{}
      }
    end)
  end

  defp find_enclosing_module(lineno, lines, module_map) do
    lines
    |> Enum.with_index(1)
    |> Enum.take(lineno - 1)
    |> Enum.reverse()
    |> Enum.find_value(fn {line, _idx} ->
      case Regex.run(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/, line) do
        [_, name] -> Map.get(module_map, name)
        nil -> nil
      end
    end)
  end

  defp find_enclosing_class(lineno, lines, class_map) do
    lines
    |> Enum.with_index(1)
    |> Enum.take(lineno - 1)
    |> Enum.reverse()
    |> Enum.find_value(fn {line, _idx} ->
      case Regex.run(~r/^\s*class\s+(\w+)/, line) do
        [_, name] -> Map.get(class_map, name)
        nil -> nil
      end
    end)
  end

  defp find_enclosing_function(lineno, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.take(lineno)
    |> Enum.reverse()
    |> Enum.find_value(fn {line, _idx} ->
      case Regex.run(~r/^\s*(defp?|defmacro|defmacrop)\s+(\S+)/, line) do
        [_, _kind, name] -> String.replace(name, ~r/[\(\),]/, "")
        nil -> nil
      end
    end)
  end

  defp func_line(lineno, lines, func_name) do
    lines
    |> Enum.with_index(1)
    |> Enum.take(lineno)
    |> Enum.reverse()
    |> Enum.find_value(fn {line, idx} ->
      if String.contains?(line, "def #{func_name}") or String.contains?(line, "defp #{func_name}") do
        idx
      end
    end) || lineno
  end
end

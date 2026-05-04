defmodule Mosaic.AST.Parser do
  @moduledoc """
  Tree-sitter bridge for parsing source files into ASTs.

  Uses `ast-grep` CLI (fast start). The `--json` flag produces a JSON CST
  that we walk to extract symbols and relationships.

  Alternative (for perf): Rustler NIF wrapping tree-sitter grammars directly.
  The module interface is the same — swap the backend and everything
  downstream works unchanged.

  ## Supported Languages

  Built-in ast-grep languages (no additional install):
  - elixir, python, rust, go, javascript, typescript, java, c, cpp, ruby

  Additional via tree-sitter npm packages:
  - kotlin, swift, scala, lua, haskell, bash, sql

  ## Usage

      iex> Parser.parse_file("lib/mosaic/api.ex")
      {:ok, %{nodes: [...], edges: [...]}}

      iex> Parser.parse_string("def foo, do: :bar", language: :elixir)
      {:ok, ast_json}
  """

  require Logger

  @default_languages ~w(elixir python rust go javascript typescript)a

  # ── File Parsing ──────────────────────────────────────────────

  @doc "Parse a single file. Detects language from extension."
  def parse_file(path, opts \\ []) do
    lang = Keyword.get(opts, :language) || detect_language(path)

    unless lang do
      {:error, "unsupported extension: #{Path.extname(path)}"}
    else
      case File.read(path) do
        {:ok, source} ->
          parse_source(source, lang, file: path, opts: opts)

        {:error, reason} ->
          {:error, "cannot read #{path}: #{reason}"}
      end
    end
  end

  @doc "Parse source string directly."
  def parse_string(source, opts \\ []) do
    lang = Keyword.fetch!(opts, :language)

    unless supports_language?(lang) do
      {:error, "unsupported language: #{lang}"}
    else
      parse_source(source, lang, opts)
    end
  end

  # ── Raw AST (--json output) ────────────────────────────────────

  @doc "Parse source and return raw ast-grep JSON CST."
  def parse_raw(source, lang) do
    with {:ok, json} <- run_ast_grep(source, lang) do
      case Jason.decode(json) do
        {:ok, ast} -> {:ok, ast}
        {:error, e} -> {:error, "JSON decode failed: #{inspect(e)}"}
      end
    end
  end

  @doc "Check if a language is supported by ast-grep."
  def supports_language?(lang) do
    lang in @default_languages
  end

  @doc "Detect language from file extension."
  def detect_language(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".heex" -> :elixir
      ".py" -> :python
      ".pyi" -> :python
      ".rs" -> :rust
      ".go" -> :go
      ".js" -> :javascript
      ".mjs" -> :javascript
      ".cjs" -> :javascript
      ".jsx" -> :javascript
      ".ts" -> :typescript
      ".tsx" -> :typescript
      ".java" -> :java
      ".c" -> :c
      ".h" -> :c
      ".cpp" -> :cpp
      ".cc" -> :cpp
      ".cxx" -> :cpp
      ".hpp" -> :cpp
      ".rb" -> :ruby
      _ -> nil
    end
  end

  # ── Private ────────────────────────────────────────────────────

  defp parse_source(source, lang, opts) do
    max_size = Keyword.get(opts, :max_size, Mosaic.Config.get(:ast_max_file_size_bytes))

    if byte_size(source) > max_size do
      {:error, "file exceeds max size #{max_size}B"}
    else
      parse_raw(source, lang)
    end
  end

  defp run_ast_grep(source, lang) do
    lang_str = Atom.to_string(lang)

    # Write source to temp file, pass as argument to ast-grep
    tmp = Path.join(System.tmp_dir!(), "mosaic_ast_#{System.unique_integer([:positive])}.tmp")
    File.write!(tmp, source)

    try do
      case System.cmd("ast-grep", ["--lang", lang_str, "--json", tmp], stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output}

        {output, _code} ->
          if String.starts_with?(String.trim(output), "{") or
             String.starts_with?(String.trim(output), "[") do
            Logger.debug("ast-grep exited non-zero but produced output: #{String.slice(output, 0, 100)}")
            {:ok, output}
          else
            Logger.debug("ast-grep failed for #{lang_str}: #{String.slice(output, 0, 200)}")
            {:error, "ast-grep parse error: #{String.slice(output, 0, 100)}"}
          end
      end
    after
      File.rm(tmp)
    end
  rescue
    e in ErlangError ->
      Logger.error("ast-grep not found: #{inspect(e)}")
      {:error, "ast-grep CLI not found. Install with: npm install -g @ast-grep/cli"}
  end
end

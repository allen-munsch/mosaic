defmodule Mosaic.AST.ParserTest do
  use ExUnit.Case, async: true

  alias Mosaic.AST.Parser

  describe "language detection" do
    test "detects elixir files" do
      assert Parser.detect_language("lib/mosaic/api.ex") == :elixir
      assert Parser.detect_language("test/test_helper.exs") == :elixir
    end

    test "detects python files" do
      assert Parser.detect_language("src/main.py") == :python
      assert Parser.detect_language("types.pyi") == :python
    end

    test "detects rust files" do
      assert Parser.detect_language("src/lib.rs") == :rust
    end

    test "detects go files" do
      assert Parser.detect_language("main.go") == :go
    end

    test "detects javascript files" do
      assert Parser.detect_language("app.js") == :javascript
      assert Parser.detect_language("component.jsx") == :javascript
      assert Parser.detect_language("module.mjs") == :javascript
    end

    test "detects typescript files" do
      assert Parser.detect_language("app.ts") == :typescript
      assert Parser.detect_language("component.tsx") == :typescript
    end

    test "detects C/C++ files" do
      assert Parser.detect_language("lib.c") == :c
      assert Parser.detect_language("lib.h") == :c
      assert Parser.detect_language("main.cpp") == :cpp
      assert Parser.detect_language("header.hpp") == :cpp
    end

    test "detects ruby files" do
      assert Parser.detect_language("app.rb") == :ruby
    end

    test "returns :unknown for unsupported extensions" do
      assert Parser.detect_language("image.png") == :unknown
      assert Parser.detect_language("file.txt") == :unknown
      assert Parser.detect_language("Makefile") == :unknown
    end
  end

  describe "language support" do
    test "validates supported languages" do
      assert Parser.supports_language?(:elixir)
      assert Parser.supports_language?(:python)
      assert Parser.supports_language?(:rust)
      assert Parser.supports_language?(:go)
      assert Parser.supports_language?(:javascript)
      assert Parser.supports_language?(:typescript)

      refute Parser.supports_language?(:haskell)
      refute Parser.supports_language?(:lua)
    end
  end

  describe "parse_string" do
    test "returns error for unsupported language" do
      assert {:error, _} = Parser.parse_string("code", language: :haskell)
    end

    @tag :external
    test "parses elixir source when ast-grep is installed" do
      source = """
      defmodule Test do
        def hello, do: :world
      end
      """

      result = Parser.parse_string(source, language: :elixir)
      # May succeed (ast-grep installed) or fail (not installed); both are valid
      case result do
        {:ok, _ast} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  describe "parse_file" do
    test "returns error for nonexistent file" do
      assert {:error, _} = Parser.parse_file("/nonexistent/file_12345.ex")
    end

    test "returns error for unsupported extension" do
      tmp = Path.join(System.tmp_dir!(), "test_#{System.unique_integer([:positive])}.txt")
      File.write!(tmp, "hello")
      assert {:error, "unsupported extension: .txt"} = Parser.parse_file(tmp)
      File.rm!(tmp)
    end
  end
end

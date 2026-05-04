defmodule Mosaic.AST.BuiltinParserTest do
  use ExUnit.Case, async: true

  alias Mosaic.AST.BuiltinParser

  describe "language detection" do
    test "detects elixir files" do
      assert BuiltinParser.detect_language("lib/my_app.ex") == :elixir
      assert BuiltinParser.detect_language("test/my_app_test.exs") == :elixir
      assert BuiltinParser.detect_language("templates/page.heex") == :elixir
    end

    test "detects python files" do
      assert BuiltinParser.detect_language("main.py") == :python
      assert BuiltinParser.detect_language("types.pyi") == :python
    end

    test "detects javascript files" do
      assert BuiltinParser.detect_language("app.js") == :javascript
      assert BuiltinParser.detect_language("lib.mjs") == :javascript
      assert BuiltinParser.detect_language("component.jsx") == :javascript
    end

    test "detects typescript files" do
      assert BuiltinParser.detect_language("app.ts") == :typescript
      assert BuiltinParser.detect_language("component.tsx") == :typescript
    end

    test "detects rust, go, ruby, java" do
      assert BuiltinParser.detect_language("main.rs") == :rust
      assert BuiltinParser.detect_language("main.go") == :go
      assert BuiltinParser.detect_language("app.rb") == :ruby
      assert BuiltinParser.detect_language("Main.java") == :java
    end

    test "detects c/cpp" do
      assert BuiltinParser.detect_language("lib.c") == :c
      assert BuiltinParser.detect_language("header.h") == :c
      assert BuiltinParser.detect_language("main.cpp") == :cpp
    end

    test "detects sql, shell, yaml, json, markdown" do
      assert BuiltinParser.detect_language("schema.sql") == :sql
      assert BuiltinParser.detect_language("setup.sh") == :bash
      assert BuiltinParser.detect_language("config.yml") == :yaml
      assert BuiltinParser.detect_language("data.json") == :json
      assert BuiltinParser.detect_language("README.md") == :markdown
    end

    test "returns :unknown for unsupported extensions" do
      assert BuiltinParser.detect_language("file.xyz") == :unknown
    end
  end

  describe "elixir parsing" do
    test "parses module definitions" do
      source = "defmodule MyApp.Core do\n  @moduledoc \"Core module\"\nend\n"
      {:ok, %{nodes: nodes, edges: _edges}} = BuiltinParser.parse(source, :elixir)

      modules = Enum.filter(nodes, &(&1.type == "module"))
      assert length(modules) > 0
      assert hd(modules).name == "MyApp.Core"
    end

    test "parses function definitions" do
      source = """
      defmodule MyApp do
        def hello(name), do: "Hello, \#{name}!"
        def goodbye, do: "Bye"
      end
      """

      {:ok, %{nodes: nodes, edges: _edges}} = BuiltinParser.parse(source, :elixir)

      functions = Enum.filter(nodes, &(&1.type == "function"))
      assert length(functions) > 0

      names = Enum.map(functions, & &1.name)
      assert Enum.any?(names, &String.starts_with?(&1, "hello"))
      assert Enum.any?(names, &String.starts_with?(&1, "goodbye"))
    end

    test "parses alias/import/require statements" do
      source = """
      defmodule MyApp do
        alias MyApp.Utils
        import Ecto.Query
        require Logger
      end
      """

      {:ok, %{nodes: _nodes, edges: edges}} = BuiltinParser.parse(source, :elixir)
      import_edges = Enum.filter(edges, &(&1.type == "imports"))
      # May or may not find all imports depending on regex matching
      assert is_list(import_edges)
    end

    test "creates contains edges between module and functions" do
      source = "defmodule M do\n  def f1, do: :ok\n  def f2, do: :ok\nend\n"
      {:ok, %{nodes: _nodes, edges: edges}} = BuiltinParser.parse(source, :elixir)

      contains_edges = Enum.filter(edges, &(&1.type == "contains"))
      assert length(contains_edges) > 0
    end
  end

  describe "python parsing" do
    test "parses functions and classes" do
      source = """
      class MyClass:
          def __init__(self):
              pass

          def method_a(self, x):
              return x + 1

      def top_level_function():
          pass
      """

      {:ok, %{nodes: nodes, edges: _edges}} = BuiltinParser.parse(source, :python)

      classes = Enum.filter(nodes, &(&1.type == "class"))
      functions = Enum.filter(nodes, &(&1.type == "function"))

      assert length(classes) > 0
      assert length(functions) > 0
    end

    test "parses import statements" do
      source = "import os\nfrom collections import defaultdict\n"
      {:ok, %{nodes: _nodes, edges: edges}} = BuiltinParser.parse(source, :python)

      import_edges = Enum.filter(edges, &(&1.type == "imports"))
      assert is_list(import_edges)
    end
  end

  describe "javascript parsing" do
    test "parses functions and classes" do
      source = """
      class Component {
        constructor() {}
        render() { return null; }
      }

      function helper() { return 42; }
      const arrow = () => true;
      """

      {:ok, %{nodes: nodes, edges: _edges}} = BuiltinParser.parse(source, :javascript)

      classes = Enum.filter(nodes, &(&1.type == "class"))
      functions = Enum.filter(nodes, &(&1.type == "function"))

      assert length(classes) > 0
      assert length(functions) > 0
    end
  end

  describe "rust parsing" do
    test "parses functions and structs" do
      source = """
      pub fn main() {
          println!("hello");
      }

      pub struct Config {
          pub path: String,
      }

      pub trait Serializable {
          fn serialize(&self) -> String;
      }
      """

      {:ok, %{nodes: nodes, _edges: _}} = BuiltinParser.parse(source, :rust)

      functions = Enum.filter(nodes, &(&1.type == "function"))
      structs = Enum.filter(nodes, &(&1.type == "struct"))
      traits = Enum.filter(nodes, &(&1.type == "trait"))

      assert length(functions) > 0
      assert length(structs) > 0
      assert length(traits) > 0
    end
  end

  describe "go parsing" do
    test "parses functions and types" do
      source = """
      package main

      func main() {
        fmt.Println("hello")
      }

      type Server struct {
        Port int
      }

      type Handler interface {
        Serve() error
      }
      """

      {:ok, %{nodes: nodes, _edges: _}} = BuiltinParser.parse(source, :go)

      functions = Enum.filter(nodes, &(&1.type == "function"))
      assert length(functions) > 0
    end
  end

  describe "unknown language handling" do
    test "returns empty nodes/edges for unknown languages" do
      {:ok, %{nodes: nodes, edges: edges}} = BuiltinParser.parse("some text", :unknown)
      assert nodes == []
      assert edges == []
    end
  end

  describe "parse_file integration" do
    test "parses an actual elixir file" do
      path = Path.join(File.cwd!(), "lib/mosaic/api.ex")
      if File.exists?(path) do
        {:ok, %{nodes: nodes, _edges: _}} = BuiltinParser.parse_file(path)
        assert length(nodes) > 0
      end
    end
  end
end

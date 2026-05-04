defmodule Mosaic.Reify do
  @moduledoc """
  Reify: S-Expression → Framework Component Transpiler Plugin System.

  Reify plugins convert Matryoshka-style S-expression DSLs into
  framework-specific code (React, Vue, Svelte, HTML, etc.). The S-expr
  serves as a compressed, framework-agnostic intermediate representation.

  Inspired by the reifyReact concept from yogthos/Matryoshka#4 and
  allen-munsch's S-expression DSL for UI components.

  ## Architecture

      S-Expression DSL
           │
      ┌────▼──────────────────────────────┐
      │  Mosaic.Reify (registry + parser)  │
      └────┬──────────────────────────────┘
           │
      ┌────▼────────┬──────────┬──────────┐
      │  React      │  Vue     │  HTML    │  ... plugins
      │  JSX/TSX    │  SFC     │  plain   │
      └─────────────┴──────────┴──────────┘

  ## Example

      iex> sexpr = "(button :variant primary :size lg :on-click handleClick (text \"Save\"))"
      iex> Reify.transpile(sexpr, :react)
      {:ok, "<button data-variant=\"primary\" data-size=\"lg\" onClick={handleClick}>..."}

      iex> Reify.transpile(sexpr, :vue)
      {:ok, "<template>\\n  <button data-variant=\"primary\" ...>..."}

  ## Creating a Plugin

      defmodule MyFramework.ReifyPlugin do
        @behaviour Mosaic.Reify.Plugin

        @impl true
        def name, do: :my_framework

        @impl true
        def transpile(ast, opts) do
          # Convert S-expr AST to your framework's code
          {:ok, generated_code}
        end
      end
  """

  @doc "Transpile an S-expression string to a target framework."
  def transpile(sexpr, framework, opts \\ []) when is_binary(sexpr) do
    with {:ok, ast} <- parse(sexpr),
         {:ok, plugin} <- get_plugin(framework) do
      plugin.transpile(ast, opts)
    end
  end

  @doc "Transpile an already-parsed AST to a target framework."
  def transpile_ast(ast, framework, opts \\ []) do
    with {:ok, plugin} <- get_plugin(framework) do
      plugin.transpile(ast, opts)
    end
  end

  @doc "Parse an S-expression string into a typed AST."
  def parse(sexpr) when is_binary(sexpr) do
    with {:ok, raw} <- Mosaic.Reify.Parser.parse(sexpr) do
      {:ok, Mosaic.Reify.AST.from_sexpr(raw)}
    end
  end

  @doc "List available reify plugins."
  def plugins do
    [
      Mosaic.Reify.React,
      Mosaic.Reify.Vue,
      Mosaic.Reify.HTML
    ]
  end

  @doc "Get a plugin by name."
  def get_plugin(name) do
    plugin = Enum.find(plugins(), &(&1.name() == name))
    if plugin, do: {:ok, plugin}, else: {:error, "Unknown reify plugin: #{name}"}
  end

  @doc "Transpile and store as a cached component in the graph."
  def reify_and_cache(sexpr, framework, name, reify_opts \\ []) do
    with {:ok, code} <- transpile(sexpr, framework, reify_opts) do
      Mosaic.Reify.Cache.store(name, sexpr, code, framework, reify_opts)
    end
  end
end

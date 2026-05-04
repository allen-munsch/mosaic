defmodule Mosaic.Reify.React do
  @moduledoc """
  S-Expression → React/JSX transpiler.

  Converts the reify component DSL into React JSX (or TSX).
  Based on allen-munsch's reifyReact design.

  ## Tag Mappings

      (button ...)  → <button ...>
      (h1 ...)      → <h1 ...>
      (text ...)    → <p ...>
      (section ...) → <section ...>

  ## Attribute Mappings (:keyword value)

      :variant primary  → data-variant="primary"
      :size lg          → data-size="lg"
      :on-click fn      → onClick={fn}
      :to "/path"       → href="/path"
      :src "img.png"    → src="img.png"

  ## Styles (inline mapping to Tailwind by default)

      :bg white         → className="bg-white"
      :font-size 2rem   → className="text-2xl"
      :padding 2rem     → className="p-8"
  """

  @behaviour Mosaic.Reify.Plugin

  # ── Tag Map ────────────────────────────────────────────────────

  @tag_map %{
    "page" => "div",
    "header" => "header",
    "main" => "main",
    "section" => "section",
    "footer" => "footer",
    "nav" => "nav",
    "aside" => "aside",
    "card" => "div",
    "form" => "form",
    "button" => "button",
    "text" => "p",
    "span" => "span",
    "link" => "a",
    "h1" => "h1", "h2" => "h2", "h3" => "h3",
    "h4" => "h4", "h5" => "h5", "h6" => "h6",
    "img" => "img",
    "input" => "input",
    "select" => "select",
    "icon" => "span",
    "badge" => "span",
    "price" => "span",
    "list" => "ul",
    "item" => "li",
    "divider" => "hr",
    "label" => "label",
    "textarea" => "textarea",
    "details" => "div",
    "summary" => "summary",
    "logo" => "div",
    "gallery" => "div",
    "breadcrumbs" => "nav",
    "crumb" => "span",
    "rating" => "div",
    "search-bar" => "div",
  }

  # ── Attribute Map ──────────────────────────────────────────────

  @attr_map %{
    ":variant" => "data-variant",
    ":size" => "data-size",
    ":width" => "data-width",
    ":count" => "data-count",
    ":on-click" => "onClick",
    ":on-change" => "onChange",
    ":on-submit" => "onSubmit",
    ":on-focus" => "onFocus",
    ":on-blur" => "onBlur",
    ":on-hover" => "onMouseEnter",
    ":on-input" => "onInput",
    ":src" => "src",
    ":alt" => "alt",
    ":href" => "href",
    ":to" => "href",
    ":placeholder" => "placeholder",
    ":value" => "value",
    ":disabled" => "disabled",
    ":required" => "required",
    ":min" => "min",
    ":max" => "max",
    ":type" => "type",
    ":name" => "name",
    ":id" => "id",
    ":class" => "className",
    ":title" => "title",
    ":role" => "role",
    ":sticky" => "data-sticky",
    ":lightbox" => "data-lightbox",
    ":shadow" => "data-shadow",
    ":current" => "aria-current",
    ":layout" => "data-layout",
    ":gap" => "data-gap",
    ":bg" => "data-bg",
    ":color" => "data-color",
  }

  @impl true
  def name, do: :react

  @impl true
  def transpile(ast, opts \\ []) do
    indent = Keyword.get(opts, :indent, 2)
    typescript = Keyword.get(opts, :typescript, false)
    component_name = Keyword.get(opts, :component_name)

    jsx = ast_to_jsx(ast, 0, indent)
    imports = collect_imports(ast)

    code = if component_name do
      """
#{if typescript, do: "import React from 'react';", else: "import React from 'react';"}
#{Enum.join(imports, "\n")}

#{if typescript, do: "export const #{component_name}: React.FC = () => (", else: "export const #{component_name} = () => ("}
#{jsx}
);
"""
    else
      jsx
    end

    {:ok, String.trim(code)}
  end

  # ── AST → JSX ──────────────────────────────────────────────────

  defp ast_to_jsx([tag | rest], depth, indent) when is_binary(tag) do
    {attrs, children} = split_attrs_and_children(rest)
    element = Map.get(@tag_map, tag, tag)

    # Handle self-closing tags
    if children == [] and tag in ~w(img input hr br) do
      "#{pad(depth, indent)}<#{element}#{render_attrs(attrs, depth, indent)} />"
    else
      child_jsx = render_children(children, depth + 1, indent)

      if child_jsx == "" do
        "#{pad(depth, indent)}<#{element}#{render_attrs(attrs, depth, indent)}></#{element}>"
      else
        "#{pad(depth, indent)}<#{element}#{render_attrs(attrs, depth, indent)}>\n#{child_jsx}\n#{pad(depth, indent)}</#{element}>"
      end
    end
  end

  defp ast_to_jsx(text, depth, indent) when is_binary(text) do
    "#{pad(depth, indent)}#{text}"
  end

  defp ast_to_jsx(num, depth, indent) when is_number(num) do
    "#{pad(depth, indent)}#{num}"
  end

  defp ast_to_jsx(_nil, _depth, _indent), do: ""

  # ── Attribute Handling ─────────────────────────────────────────

  defp split_attrs_and_children(items) do
    split_attrs_and_children(items, [], [])
  end

  defp split_attrs_and_children([], attrs, children) do
    {Enum.reverse(attrs), Enum.reverse(children)}
  end

  # Keyword-value pair
  defp split_attrs_and_children([key, value | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_attrs_and_children(rest, [{key, value} | attrs], children)
  end

  # Keyword without explicit value (boolean flag)
  defp split_attrs_and_children([key | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_attrs_and_children(rest, [{key, true} | attrs], children)
  end

  # Style block: (styles :bg white :font bold) inside component
  defp split_attrs_and_children([["styles" | style_attrs] | rest], attrs, children) do
    # Convert style attributes to className
    class_name = styles_to_classname(style_attrs)
    split_attrs_and_children(rest, [{":class", class_name} | attrs], children)
  end

  # Nested list → child component
  defp split_attrs_and_children([item | rest], attrs, children) when is_list(item) do
    split_attrs_and_children(rest, attrs, [item | children])
  end

  # Plain text child
  defp split_attrs_and_children([item | rest], attrs, children) do
    split_attrs_and_children(rest, attrs, [item | children])
  end

  # ── Attribute Rendering ────────────────────────────────────────

  defp render_attrs(attrs, _depth, _indent) do
    rendered =
      attrs
      |> Enum.map(fn
        {key, true} ->
          attr_name = Map.get(@attr_map, key, String.replace_prefix(key, ":", ""))
          " #{attr_name}"

        {key, value} when is_binary(value) ->
          attr_name = Map.get(@attr_map, key, String.replace_prefix(key, ":", ""))

          # Event handlers → {handler}
          if String.starts_with?(attr_name, "on") do
            " #{attr_name}={#{value}}"
          else
            " #{attr_name}=\"#{value}\""
          end

        {key, value} ->
          attr_name = Map.get(@attr_map, key, String.replace_prefix(key, ":", ""))
          " #{attr_name}={#{value}}"
      end)
      |> Enum.join("")

    rendered
  end

  # ── Children Rendering ─────────────────────────────────────────

  defp render_children(children, depth, indent) do
    children
    |> Enum.map(fn
      child when is_list(child) -> ast_to_jsx(child, depth, indent)
      text when is_binary(text) -> "#{pad(depth, indent)}#{text}"
      num when is_number(num) -> "#{pad(depth, indent)}#{num}"
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # ── Style to Tailwind / ClassName ───────────────────────────────

  defp styles_to_classname(style_attrs) do
    style_attrs
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [key, value] -> style_to_tailwind(key, value)
      [key] -> style_to_tailwind(key, true)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp style_to_tailwind(key, value) do
    case {key, value} do
      {:bg, color} -> "bg-#{color}"
      {:color, color} -> "text-#{color}"
      {:font, weight} when weight in ~w(bold semibold normal light) -> "font-#{weight}"
      {:font, _} -> ""
      {:spacing, size} -> if is_binary(size), do: "gap-#{size}", else: ""
      {:radius, size} -> if is_binary(size), do: "rounded-#{size}", else: ""
      {:shadow, size} -> if is_binary(size), do: "shadow-#{size}", else: ""
      {:animate, type} -> if is_binary(type), do: "animate-#{type}", else: ""
      {:aspect_ratio, _} -> "aspect-square"
      {:layout, _} -> ""
      _ -> ""
    end
  end

  # ── Imports ────────────────────────────────────────────────────

  defp collect_imports(_ast), do: []

  # ── Helpers ────────────────────────────────────────────────────

  defp pad(depth, indent) do
    String.duplicate(" ", depth * indent)
  end
end

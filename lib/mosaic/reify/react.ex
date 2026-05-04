defmodule Mosaic.Reify.React do
  @moduledoc """
  S-Expression AST → React/JSX transpiler with full expression support.

  Handles: conditionals (if), loops (foreach), expressions (equals, count,
  concat, toString), event handlers, style blocks, and component composition.
  Produces clean, idiomatic React JSX with proper indentation.
  """

  @behaviour Mosaic.Reify.Plugin

  alias Mosaic.Reify.AST, as: AST

  @tag_map %{
    "page" => "div", "header" => "header", "main" => "main", "section" => "section",
    "footer" => "footer", "nav" => "nav", "aside" => "aside",
    "card" => "div", "form" => "form", "button" => "button",
    "text" => "p", "span" => "span", "link" => "a",
    "h1" => "h1", "h2" => "h2", "h3" => "h3", "h4" => "h4", "h5" => "h5", "h6" => "h6",
    "img" => "img", "input" => "input", "select" => "select",
    "textarea" => "textarea", "label" => "label",
    "icon" => "span", "badge" => "span", "price" => "span",
    "list" => "ul", "item" => "li", "divider" => "hr",
    "checkbox" => "input", "tabs" => "div", "tab" => "button",
    "details" => "div", "summary" => "summary",
    "gallery" => "div", "breadcrumbs" => "nav", "crumb" => "span",
    "rating" => "div", "search-bar" => "input", "modal" => "div",
    "drawer" => "div", "logo" => "div", "quantity-selector" => "div",
  }

  @attr_map %{
    ":variant" => "data-variant", ":size" => "data-size",
    ":width" => "data-width", ":count" => "data-count",
    ":on-click" => "onClick", ":on-change" => "onChange",
    ":on-submit" => "onSubmit", ":on-focus" => "onFocus",
    ":on-blur" => "onBlur", ":on-hover" => "onMouseEnter",
    ":on-input" => "onInput", ":src" => "src", ":alt" => "alt",
    ":href" => "href", ":to" => "href", ":placeholder" => "placeholder",
    ":value" => "value", ":disabled" => "disabled", ":required" => "required",
    ":min" => "min", ":max" => "max", ":type" => "type", ":name" => "name",
    ":id" => "id", ":class" => "className", ":title" => "title",
    ":checked" => "checked",
    ":key" => "key",
    ":padding" => "data-padding", ":margin" => "data-margin",
    ":margin-top" => "data-margin-top", ":margin-bottom" => "data-margin-bottom",
    ":margin-x" => "data-margin-x", ":margin-y" => "data-margin-y",
    ":padding-top" => "data-padding-top",
    ":max-width" => "data-max-width",
    ":text-align" => "data-text-align", ":text-decoration" => "data-text-decoration",
    ":font-size" => "data-font-size", ":font-weight" => "data-font-weight",
    ":color" => "data-color", ":bg" => "data-bg",
    ":shadow" => "data-shadow", ":radius" => "data-radius",
    ":border" => "data-border", ":border-top" => "data-border-top",
    ":border-color" => "data-border-color",
    ":flex" => "data-flex", ":gap" => "data-gap",
    ":align" => "data-align", ":justify" => "data-justify",
    ":style-type" => "data-style-type",
    ":sticky" => "data-sticky", ":current" => "aria-current",
    ":layout" => "data-layout", ":lightbox" => "data-lightbox",
  }

  @self_closing ~w(img input hr br)

  @impl true
  def name, do: :react

  @impl true
  def transpile(ast, opts \\ [])

  def transpile(ast, opts) when is_list(ast) do
    transpile(AST.from_sexpr(ast), opts)
  end

  def transpile(%AST.Node{} = node, opts) do
    indent = Keyword.get(opts, :indent, 2)
    component_name = Keyword.get(opts, :component_name)
    typescript = Keyword.get(opts, :typescript, false)

    body = node_to_jsx(node, 0, indent)
    imports = collect_imports(node)

    code = if component_name do
      """
      #{Enum.join(imports, "\n")}

      #{if typescript, do: "export const #{component_name}: React.FC = () => (", else: "export const #{component_name} = () => ("}
      #{body}
      );
      """
    else
      body
    end

    {:ok, String.trim(code)}
  end

  def transpile(other, _opts), do: {:ok, inspect(other)}

  # ── Node → JSX ────────────────────────────────────────────────

  defp node_to_jsx(%AST.Node{tag: tag, attrs: attrs, children: children}, depth, indent) do
    element = Map.get(@tag_map, tag, tag)
    rendered_attrs = render_attrs(attrs, depth, indent)

    if children == [] and element in @self_closing do
      "#{pad(depth)}<#{element}#{rendered_attrs} />"
    else
      child_jsx = render_children(children, depth + 1, indent)

      if String.trim(child_jsx) == "" do
        "#{pad(depth)}<#{element}#{rendered_attrs}></#{element}>"
      else
        "#{pad(depth)}<#{element}#{rendered_attrs}>\n#{child_jsx}\n#{pad(depth)}</#{element}>"
      end
    end
  end

  defp node_to_jsx(%AST.Expr{type: :if, args: [cond, then_expr, else_expr]}, depth, indent) do
    cond_js = expr_to_js(cond)
    then_jsx = node_to_jsx(then_expr, depth + 1, indent)

    if else_expr do
      else_jsx = node_to_jsx(else_expr, depth + 1, indent)
      "#{pad(depth)}{#{cond_js} ? (\n#{then_jsx}\n#{pad(depth)}) : (\n#{else_jsx}\n#{pad(depth)})}"
    else
      "#{pad(depth)}{#{cond_js} && (\n#{then_jsx}\n#{pad(depth)})}"
    end
  end

  defp node_to_jsx(%AST.Expr{type: :foreach, args: [var, coll, body]}, depth, indent) do
    coll_js = expr_to_js(coll)
    inner = node_to_jsx(body, depth + indent, indent)
    "#{pad(depth)}{#{coll_js}.map((#{var}) => (\n#{inner}\n#{pad(depth)}))}"
  end

  defp node_to_jsx(text, depth, _indent) when is_binary(text), do: "#{pad(depth)}{#{inspect(text)}}"
  defp node_to_jsx(num, depth, _indent) when is_number(num), do: "#{pad(depth)}{#{num}}"
  defp node_to_jsx(nil, _depth, _indent), do: ""

  # ── Expression → JavaScript ───────────────────────────────────

  defp expr_to_js(%AST.Expr{type: :equals, args: [a, b]}), do: "#{expr_to_js(a)} === #{expr_to_js(b)}"
  defp expr_to_js(%AST.Expr{type: :not, args: [a]}), do: "!#{expr_to_js(a)}"
  defp expr_to_js(%AST.Expr{type: :count, args: [coll]}), do: "#{expr_to_js(coll)}.length"
  defp expr_to_js(%AST.Expr{type: :concat, args: [a, b]}), do: "#{expr_to_js(a)} + #{expr_to_js(b)}"
  defp expr_to_js(%AST.Expr{type: :toString, args: [a]}), do: "String(#{expr_to_js(a)})"
  defp expr_to_js(v) when is_binary(v) do
    # If it looks like a property access (contains '.'), treat as expression
    # Otherwise wrap in quotes as a string literal
    if String.contains?(v, ".") or String.match?(v, ~r/^[a-z][A-Z]/) do
      v
    else
      # Check if it's a known variable reference or a literal string
      # Heuristic: single lowercase word → variable, multi-word or mixed case → string
      if String.match?(v, ~r/^[a-z_][a-zA-Z0-9_]*$/) and v not in ~w(true false null undefined) do
        v
      else
        inspect(v)
      end
    end
  end
  defp expr_to_js(v) when is_number(v), do: "#{v}"

  # ── Attribute Rendering ───────────────────────────────────────

  defp render_attrs(attrs, _depth, _indent) do
    attrs
    |> Enum.map(fn %AST.Attr{key: key, value: value} ->
      attr_name = Map.get(@attr_map, key, String.replace_leading(key, ":", ""))
      event? = String.starts_with?(attr_name, "on")

      rendered = render_attr_value(value, event?)

      if event? do
        " #{attr_name}={#{rendered}}"
      else
        " #{attr_name}=\"#{rendered}\""
      end
    end)
    |> Enum.join("")
  end

  defp render_attr_value(%AST.Expr{} = expr, true), do: "(e) => #{expr_to_js(expr)}"
  defp render_attr_value(%AST.Expr{} = expr, false), do: "{#{expr_to_js(expr)}}"
  defp render_attr_value(v, true) when is_binary(v) do
    # Event handlers: if looks like a variable, render as {handler}
    # If it's a dot-notation call like "handleFilterChange" with args, keep as-is
    v
  end

  defp render_attr_value(v, false) when is_binary(v) do
    # Static attributes: check if value contains '.' (property access) → render as expression
    if String.contains?(v, ".") do
      "{#{v}}"
    else
      v
    end
  end
  defp render_attr_value(v, _) when is_boolean(v), do: "#{v}"
  defp render_attr_value(v, _) when is_number(v), do: "#{v}"

  # ── Children Rendering ────────────────────────────────────────

  defp render_children(children, depth, indent) do
    children
    |> Enum.map(&node_to_jsx(&1, depth, indent))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp collect_imports(_node), do: []

  defp pad(depth), do: String.duplicate(" ", depth)
end

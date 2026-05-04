defmodule Mosaic.Reify.HTML do
  @moduledoc """
  S-Expression → Plain HTML transpiler.

  No framework, no JSX, no Vue — just clean HTML with data attributes.
  """

  @behaviour Mosaic.Reify.Plugin

  @impl true
  def name, do: :html

  @impl true
  def transpile(ast, opts \\ []) do
    indent = Keyword.get(opts, :indent, 2)
    {:ok, ast_to_html(ast, 0, indent)}
  end

  defp ast_to_html([tag | rest], depth, indent) when is_binary(tag) do
    {attrs, children} = split_html_attrs(rest)
    element = Map.get(html_tag_map(), tag, tag)

    rendered_attrs = render_html_attrs(attrs)

    if children == [] and tag in ~w(img input hr br) do
      "#{pad(depth, indent)}<#{element}#{rendered_attrs}>"
    else
      child_html = children
        |> Enum.map(fn
          c when is_list(c) -> ast_to_html(c, depth + 1, indent)
          t when is_binary(t) -> "#{pad(depth + 1, indent)}#{t}"
          _ -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      if child_html == "" do
        "#{pad(depth, indent)}<#{element}#{rendered_attrs}></#{element}>"
      else
        "#{pad(depth, indent)}<#{element}#{rendered_attrs}>\n#{child_html}\n#{pad(depth, indent)}</#{element}>"
      end
    end
  end

  defp ast_to_html(text, depth, indent) when is_binary(text) do
    "#{pad(depth, indent)}#{text}"
  end

  defp ast_to_html(_nil, _depth, _indent), do: ""

  defp html_tag_map do
    %{
      "text" => "p", "link" => "a", "icon" => "i", "badge" => "span",
      "price" => "span", "number-input" => "input", "search-bar" => "input",
    }
  end

  defp split_html_attrs(items), do: split_html_attrs(items, [], [])
  defp split_html_attrs([], attrs, children), do: {Enum.reverse(attrs), Enum.reverse(children)}
  defp split_html_attrs([key, value | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_html_attrs(rest, [{key, value} | attrs], children)
  end
  defp split_html_attrs([key | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_html_attrs(rest, [{key, true} | attrs], children)
  end
  defp split_html_attrs([["styles" | _s] | rest], attrs, children), do: split_html_attrs(rest, attrs, children)
  defp split_html_attrs([item | rest], attrs, children) when is_list(item), do: split_html_attrs(rest, attrs, [item | children])
  defp split_html_attrs([item | rest], attrs, children), do: split_html_attrs(rest, attrs, [item | children])

  defp render_html_attrs(attrs) do
    attrs
    |> Enum.map(fn
      {":on-click", handler} -> " onclick=\"#{handler}(event)\""
      {":on-change", handler} -> " onchange=\"#{handler}(event)\""
      {":on-submit", handler} -> " onsubmit=\"#{handler}(event)\""
      {":to", path} -> " href=\"#{path}\""
      {":src", src} -> " src=\"#{src}\""
      {":href", href} -> " href=\"#{href}\""
      {":disabled", true} -> " disabled"
      {":required", true} -> " required"
      {key, value} when is_binary(value) -> " #{String.replace_prefix(key, ":", "")}=\"#{value}\""
      {key, true} -> " #{String.replace_prefix(key, ":", "")}"
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp pad(depth, indent), do: String.duplicate(" ", depth * indent)
end

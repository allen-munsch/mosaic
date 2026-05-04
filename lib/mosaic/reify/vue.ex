defmodule Mosaic.Reify.Vue do
  @moduledoc """
  S-Expression → Vue Single File Component (SFC) transpiler.

  Converts reify DSL into Vue 3 SFC with <template>, <script setup>,
  and <style scoped> sections.
  """

  @behaviour Mosaic.Reify.Plugin

  @impl true
  def name, do: :vue

  @impl true
  def transpile(ast, opts \\ []) do
    component_name = Keyword.get(opts, :component_name, "ReifiedComponent")
    script_setup = Keyword.get(opts, :script_setup, true)
    typescript = Keyword.get(opts, :typescript, false)

    template = ast_to_template(ast, 0, 2)

    lang_attr = if typescript, do: " lang=\"ts\"", else: ""

    {:ok, """
<template>
#{template}
</template>

<script setup#{lang_attr}>
// Props, emits, and logic go here
</script>

<style scoped>
/* Component styles */
</style>
""" |> String.trim()}
  end

  defp ast_to_template([tag | rest], depth, indent) when is_binary(tag) do
    {attrs, children} = split_vue_attrs(rest)
    element = vue_element(tag)

    rendered_attrs = render_vue_attrs(attrs)

    if children == [] do
      "#{pad(depth, indent)}<#{element}#{rendered_attrs} />"
    else
      child_html = render_vue_children(children, depth + 1, indent)
      "#{pad(depth, indent)}<#{element}#{rendered_attrs}>\n#{child_html}\n#{pad(depth, indent)}</#{element}>"
    end
  end

  defp ast_to_template(text, depth, indent) when is_binary(text) do
    "#{pad(depth, indent)}{{ #{text} }}"
  end

  defp ast_to_template(_nil, _depth, _indent), do: ""

  defp vue_element(tag) do
    case tag do
      "text" -> "p"
      "link" -> "a"
      "icon" -> "i"
      "badge" -> "span"
      "price" -> "span"
      "number-input" -> "input"
      t -> t
    end
  end

  defp split_vue_attrs(items), do: split_vue_attrs(items, [], [])
  defp split_vue_attrs([], attrs, children), do: {Enum.reverse(attrs), Enum.reverse(children)}
  defp split_vue_attrs([key, value | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_vue_attrs(rest, [{key, value} | attrs], children)
  end
  defp split_vue_attrs([key | rest], attrs, children) when is_binary(key) and key != "" and binary_part(key, 0, 1) == ":" do
    split_vue_attrs(rest, [{key, true} | attrs], children)
  end
  defp split_vue_attrs([["styles" | _style_attrs] | rest], attrs, children) do
    split_vue_attrs(rest, attrs, children)
  end
  defp split_vue_attrs([item | rest], attrs, children) when is_list(item) do
    split_vue_attrs(rest, attrs, [item | children])
  end
  defp split_vue_attrs([item | rest], attrs, children) do
    split_vue_attrs(rest, attrs, [item | children])
  end

  defp render_vue_attrs(attrs) do
    attrs
    |> Enum.map(fn
      {":on-click", handler} -> " @click=\"#{handler}\""
      {":on-change", handler} -> " @change=\"#{handler}\""
      {":on-submit", handler} -> " @submit=\"#{handler}\""
      {":on-input", handler} -> " @input=\"#{handler}\""
      {":to", path} -> " :to=\"'#{path}'\""
      {":src", src} -> " :src=\"'#{src}'\""
      {":href", href} -> " :href=\"'#{href}'\""
      {":variant", v} -> " data-variant=\"#{v}\""
      {":size", s} -> " data-size=\"#{s}\""
      {":disabled", true} -> " disabled"
      {":required", true} -> " required"
      {key, value} when is_binary(value) -> " #{String.replace_prefix(key, ":", "")}=\"#{value}\""
      {key, true} -> " #{String.replace_prefix(key, ":", "")}"
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp render_vue_children(children, depth, indent) do
    children
    |> Enum.map(fn
      child when is_list(child) -> ast_to_template(child, depth, indent)
      text when is_binary(text) -> "#{pad(depth, indent)}{{ #{text} }}"
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp pad(depth, indent), do: String.duplicate(" ", depth * indent)
end

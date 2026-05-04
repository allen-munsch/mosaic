defmodule Mosaic.Reify.AST do
  @moduledoc """
  Typed AST for the reify S-expression DSL. Parsed from S-exprs,
  consumed by framework transpilers. Supports round-tripping.
  """

  defmodule Node do
    defstruct [:tag, :attrs, :children, :meta]
  end

  defmodule Attr do
    defstruct [:key, :value]
  end

  defmodule Expr do
    defstruct [:type, :args]
  end

  @type t :: %Node{tag: String.t(), attrs: [%Attr{}], children: [t() | String.t() | %Expr{}], meta: map()}

  @doc "Parse raw S-expression list into typed AST."
  def from_sexpr(["foreach", var, coll, body]) do
    %Expr{type: :foreach, args: [var, from_sexpr(coll), from_sexpr(body)]}
  end

  def from_sexpr(["if", cond_expr, then_expr, else_expr]) do
    %Expr{type: :if, args: [from_sexpr(cond_expr), from_sexpr(then_expr), from_sexpr(else_expr)]}
  end

  def from_sexpr(["if", cond_expr, then_expr]) do
    %Expr{type: :if, args: [from_sexpr(cond_expr), from_sexpr(then_expr), nil]}
  end

  def from_sexpr(["equals", a, b]) do
    %Expr{type: :equals, args: [a, b]}
  end

  def from_sexpr(["not", a]) do
    %Expr{type: :not, args: [a]}
  end

  def from_sexpr(["count", coll]) do
    %Expr{type: :count, args: [coll]}
  end

  def from_sexpr(["concat", a, b]) do
    %Expr{type: :concat, args: [a, b]}
  end

  def from_sexpr(["toString", a]) do
    %Expr{type: :toString, args: [a]}
  end

  def from_sexpr([tag | rest]) when is_binary(tag) do
    {attrs, children} = split_attrs_children(rest)
    %Node{tag: tag, attrs: attrs, children: children, meta: %{}}
  end

  def from_sexpr(v) when is_binary(v), do: v
  def from_sexpr(v) when is_number(v), do: v
  def from_sexpr(v) when is_boolean(v), do: v
  def from_sexpr(nil), do: nil

  defp split_attrs_children(items, attrs \\ [], children \\ [])
  defp split_attrs_children([], attrs, children), do: {Enum.reverse(attrs), Enum.reverse(children)}

  # :keyword value
  defp split_attrs_children([k, v | rest], attrs, children) when is_binary(k) and k != "" and binary_part(k, 0, 1) == ":" and not is_list(v) do
    split_attrs_children(rest, [%Attr{key: k, value: v} | attrs], children)
  end

  # :keyword (boolean flag — next item is list or keyword)
  defp split_attrs_children([k | rest], attrs, children) when is_binary(k) and k != "" and binary_part(k, 0, 1) == ":" do
    case rest do
      [next | _] when is_list(next) ->
        split_attrs_children(rest, [%Attr{key: k, value: from_sexpr(next)} | attrs], children)
      [next | _] when is_binary(next) and next != "" and binary_part(next, 0, 1) == ":" ->
        split_attrs_children(rest, [%Attr{key: k, value: true} | attrs], children)
      _ ->
        split_attrs_children(rest, [%Attr{key: k, value: true} | attrs], children)
    end
  end

  # Nested list → child
  defp split_attrs_children([item | rest], attrs, children) when is_list(item) do
    split_attrs_children(rest, attrs, [from_sexpr(item) | children])
  end

  # Plain atom → text child
  defp split_attrs_children([item | rest], attrs, children) do
    split_attrs_children(rest, attrs, [item | children])
  end
end

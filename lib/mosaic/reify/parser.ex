defmodule Mosaic.Reify.Parser do
  @moduledoc """
  Minimal S-expression parser for the reify DSL.

  Parses strings like:
    (button :variant primary :size lg :on-click handleClick (text "Save"))
  into nested lists:
    ["button", ":variant", "primary", ":size", "lg", ":on-click", "handleClick",
     ["text", "Save"]]

  Supports:
    - Atoms: button, primary, handleClick
    - Keywords: :variant, :size
    - Strings: "Save"
    - Numbers: 42, 3.14
    - Nested lists: (text "Save")
    - Attributes with values: :variant primary
  """

  @doc "Parse an S-expression string into a nested list AST."
  def parse(sexpr) when is_binary(sexpr) do
    tokens = tokenize(sexpr)
    {ast, []} = parse_tokens(tokens)
    {:ok, ast}
  rescue
    e -> {:error, "Parse error: #{Exception.message(e)}"}
  end

  # ── Tokenizer ──────────────────────────────────────────────────

  defp tokenize(sexpr) do
    sexpr
    |> String.replace(~r/;.*$/, "")  # strip comments
    |> tokenize_chars([])
    |> Enum.reverse()
  end

  defp tokenize_chars("", acc), do: acc

  defp tokenize_chars(<<"(", rest::binary>>, acc) do
    tokenize_chars(rest, ["(" | acc])
  end

  defp tokenize_chars(<<")", rest::binary>>, acc) do
    tokenize_chars(rest, [")" | acc])
  end

  defp tokenize_chars(<<"\"", rest::binary>>, acc) do
    {string, after_string} = read_string(rest, "")
    tokenize_chars(after_string, [string | acc])
  end

  defp tokenize_chars(<<c, rest::binary>>, acc) when c in ~c[ \t\n\r] do
    tokenize_chars(rest, acc)
  end

  defp tokenize_chars(rest, acc) do
    {token, after_token} = read_atom(rest, "")
    tokenize_chars(after_token, [token | acc])
  end

  defp read_string(<<"\\\"", rest::binary>>, acc) do
    read_string(rest, acc <> "\"")
  end

  defp read_string(<<"\"", rest::binary>>, acc) do
    {acc, rest}
  end

  defp read_string(<<c, rest::binary>>, acc) do
    read_string(rest, acc <> <<c>>)
  end

  defp read_string(<<>>, acc) do
    {acc, ""}
  end

  defp read_atom(<<c, rest::binary>>, acc) when c in ~c[ \t\n\r()], do: {acc, <<c, rest::binary>>}
  defp read_atom(<<c, rest::binary>>, acc), do: read_atom(rest, acc <> <<c>>)
  defp read_atom(<<>>, acc), do: {acc, ""}

  # ── Parser ─────────────────────────────────────────────────────

  defp parse_tokens(["(" | rest]) do
    {items, after_list} = parse_list(rest, [])
    {items, after_list}
  end

  defp parse_tokens([token | rest]) do
    {parse_atom(token), rest}
  end

  defp parse_tokens([]), do: {nil, []}

  defp parse_list([")" | rest], acc) do
    {Enum.reverse(acc), rest}
  end

  defp parse_list(["(" | rest], acc) do
    {sublist, after_sublist} = parse_list(rest, [])
    parse_list(after_sublist, [sublist | acc])
  end

  defp parse_list([token | rest], acc) do
    parse_list(rest, [parse_atom(token) | acc])
  end

  defp parse_list([], _acc) do
    raise "Unclosed parenthesis"
  end

  # ── Atom Parser ────────────────────────────────────────────────

  defp parse_atom(token) do
    cond do
      String.starts_with?(token, "\"") and String.ends_with?(token, "\"") ->
        String.slice(token, 1..-2//1)

      String.match?(token, ~r/^-?\d+\.\d+$/) ->
        String.to_float(token)

      String.match?(token, ~r/^-?\d+$/) ->
        String.to_integer(token)

      token == "true" -> true
      token == "false" -> false
      token == "nil" -> nil

      true ->
        token
    end
  end
end

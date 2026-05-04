defmodule Mosaic.Reify.Plugin do
  @moduledoc """
  Behaviour for reify plugins. Each plugin transpiles S-expression ASTs
  into a specific framework's code output.
  """

  @callback name() :: atom()
  @callback transpile(ast :: list(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}

  @optional_callbacks []
end

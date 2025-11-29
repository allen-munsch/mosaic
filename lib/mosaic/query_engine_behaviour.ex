defmodule Mosaic.QueryEngine.Behaviour do
  @moduledoc """
  Behaviour for the Mosaic Query Engine.
  """

  @callback execute_query(query_text :: String.t(), opts :: Keyword.t()) :: {:ok, list()} | {:error, any()}

  # Workaround for Mox __mock_for__ error
  def __mock_for__(), do: Mosaic.QueryEngine
end
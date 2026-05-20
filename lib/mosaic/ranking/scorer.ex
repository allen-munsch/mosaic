defmodule Mosaic.Ranking.Scorer do
  @moduledoc """
  Behaviour for individual scoring functions.
  Each scorer produces a normalized score in [0, 1].
  """

  @type document :: map()
  @type context :: map()  # Query context, user info, etc.
  @type score :: float()

  @callback name() :: atom()
  @callback score(document(), context()) :: score()
  @callback weight() :: float()  # Default weight for this scorer
end

defmodule Mosaic.Cache do
  @moduledoc """
  Behaviour for cache implementations.
  Allows swapping Redis for ETS, Cachex, or anything else.
  """

  @type key :: binary()
  @type value :: term()
  @type ttl :: pos_integer() | :infinity
  @type name :: atom() | pid()

  @callback get(key(), name) :: {:ok, value()} | :miss | {:error, term()}
  @callback put(key(), value(), ttl(), name) :: :ok | {:error, term()}
  @callback delete(key(), name) :: :ok | {:error, term()}
  @callback clear(name) :: :ok | {:error, term()}

  # Optional batch operations
  @callback get_many([key()], name) :: %{key() => value()}
  @callback put_many([{key(), value()}], ttl(), name) :: :ok | {:error, term()}

  @optional_callbacks get_many: 2, put_many: 3
end
defmodule Mosaic.Index.Binary.Quantizer do
  @moduledoc "Converts float vectors to binary codes"
  
  defstruct [:thresholds, :method, :trained]
  
  @doc "Encode a float vector to binary"
  def encode(vector, nil, config) do
    # Initialize quantizer with mean thresholds
    thresholds = List.duplicate(0.0, length(vector))
    state = %__MODULE__{thresholds: thresholds, method: config.quantization, trained: false}
    encode(vector, state, config)
  end
  
  def encode(vector, %__MODULE__{} = state, _config) do
    binary = vector
    |> Enum.zip(state.thresholds)
    |> Enum.map(fn {v, t} -> if v >= t, do: 1, else: 0 end)
    |> bits_to_binary()
    
    # Update running mean for thresholds (online learning)
    new_thresholds = if state.trained do
      state.thresholds
    else
      Enum.zip(state.thresholds, vector)
      |> Enum.map(fn {t, v} -> t * 0.99 + v * 0.01 end)
    end
    
    {binary, %{state | thresholds: new_thresholds}}
  end
  
  defp bits_to_binary(bits) do
    bits
    |> Enum.chunk_every(8, 8, [0, 0, 0, 0, 0, 0, 0, 0])
    |> Enum.map(&bits_to_byte/1)
    |> :binary.list_to_bin()
  end
  
  defp bits_to_byte([b7, b6, b5, b4, b3, b2, b1, b0]) do
    b7 * 128 + b6 * 64 + b5 * 32 + b4 * 16 + b3 * 8 + b2 * 4 + b1 * 2 + b0
  end
end

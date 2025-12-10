defmodule Mosaic.Index.Binary.QuantizerTest do
  use ExUnit.Case, async: true
  alias Mosaic.Index.Binary.Quantizer

  test "encode converts vector to binary" do
    vector = [0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5]
    config = %{quantization: :mean}
    {binary, _state} = Quantizer.encode(vector, nil, config)
    assert is_bitstring(binary)
  end

  test "encode produces consistent output for same input" do
    vector = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
    config = %{quantization: :mean}
    {bin1, state1} = Quantizer.encode(vector, nil, config)
    {bin2, _state2} = Quantizer.encode(vector, state1, config)
    assert bin1 == bin2
  end

  test "different vectors produce different binaries" do
    config = %{quantization: :mean}
    v1 = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    v2 = [-1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0]
    {bin1, state} = Quantizer.encode(v1, nil, config)
    {bin2, _} = Quantizer.encode(v2, state, config)
    assert bin1 != bin2
  end
end

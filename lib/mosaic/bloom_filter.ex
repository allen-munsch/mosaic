defmodule BloomFilter do
  defstruct [:bits, :size, :num_hashes]

  def new(size, num_hashes) do
    %__MODULE__{
      bits: :array.new(size, default: 0),
      size: size,
      num_hashes: num_hashes
    }
  end

  def add(%__MODULE__{} = bloom, item) do
    indices = hash_indices(item, bloom.size, bloom.num_hashes)
    new_bits = Enum.reduce(indices, bloom.bits, fn idx, bits ->
      :array.set(idx, 1, bits)
    end)
    %{bloom | bits: new_bits}
  end

  def member?(%__MODULE__{} = bloom, item) do
    indices = hash_indices(item, bloom.size, bloom.num_hashes)
    Enum.all?(indices, fn idx ->
      :array.get(idx, bloom.bits) == 1
    end)
  end

  defp hash_indices(item, size, num_hashes) do
    base_hash = :erlang.phash2(item)
    for i <- 0..(num_hashes - 1) do
      rem(base_hash + i * :erlang.phash2(i), size)
    end
  end

  def to_binary(%__MODULE__{} = bloom) do
    :erlang.term_to_binary(bloom)
  end

  def from_binary(binary) do
    :erlang.binary_to_term(binary)
  end
end

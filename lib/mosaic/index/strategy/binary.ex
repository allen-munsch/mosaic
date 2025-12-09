defmodule Mosaic.Index.Strategy.Binary do
  @moduledoc """
  Binary embedding index using XOR + POPCNT for ultra-fast similarity.
  
  Converts float vectors to binary codes and uses Hamming distance.
  Extremely fast on modern CPUs with POPCNT instruction.
  
  Configuration:
  - :bits - Number of bits per vector (default: 256)
  - :quantization - :mean | :median | :learned (default: :mean)
  - :multi_probe - Number of probes for accuracy (default: 1)
  - :index_type - :flat | :ivf (default: :flat)
  """
  
  @behaviour Mosaic.Index.Strategy
  require Logger
  
  alias Mosaic.Index.Binary.Quantizer
  
  defstruct [
    :base_path,
    :bits,
    :quantization,
    :multi_probe,
    :index_type,
    :quantizer_state,
    :storage,
    :doc_count
  ]
  
  @default_bits 256
  @default_quantization :mean
  
  @impl true
  def init(opts) do
    config = %__MODULE__{
      base_path: Keyword.get(opts, :base_path, Path.join(Mosaic.Config.get(:storage_path), "binary_index")),
      bits: Keyword.get(opts, :bits, @default_bits),
      quantization: Keyword.get(opts, :quantization, @default_quantization),
      multi_probe: Keyword.get(opts, :multi_probe, 1),
      index_type: Keyword.get(opts, :index_type, :flat),
      quantizer_state: nil,
      storage: %{},
      doc_count: 0
    }
    
    File.mkdir_p!(config.base_path)
    {:ok, config}
  end
  
  @impl true
  def index_document(doc, embedding, state) do
    # Quantize float vector to binary
    {binary_code, new_quantizer} = Quantizer.encode(embedding, state.quantizer_state, state)
    
    entry = %{
      id: doc.id,
      binary_code: binary_code,
      metadata: doc.metadata
    }
    
    new_storage = Map.put(state.storage, doc.id, entry)
    
    {:ok, %{state | 
      storage: new_storage,
      quantizer_state: new_quantizer,
      doc_count: state.doc_count + 1
    }}
  end
  
  @impl true
  def index_batch(docs, state) do
    # Batch encode for efficiency
    {entries, new_quantizer} = Enum.map_reduce(docs, state.quantizer_state, fn {doc, embedding}, q_state ->
      {binary_code, new_q} = Quantizer.encode(embedding, q_state, state)
      entry = %{id: doc.id, binary_code: binary_code, metadata: doc.metadata}
      {entry, new_q}
    end)
    
    new_storage = Enum.reduce(entries, state.storage, fn entry, storage ->
      Map.put(storage, entry.id, entry)
    end)
    
    {:ok, %{state |
      storage: new_storage,
      quantizer_state: new_quantizer,
      doc_count: state.doc_count + length(docs)
    }}
  end
  
  @impl true
  def delete_document(doc_id, state) do
    new_storage = Map.delete(state.storage, doc_id)
    {:ok, %{state | storage: new_storage, doc_count: state.doc_count - 1}}
  end
  
  @impl true
  def find_candidates(query_embedding, opts, state) do
    limit = Keyword.get(opts, :limit, 20)
    
    # Quantize query
    {query_binary, _} = Quantizer.encode(query_embedding, state.quantizer_state, state)
    
    # Compute Hamming distances using XOR + POPCNT
    results = state.storage
    |> Enum.map(fn {_id, entry} ->
      distance = hamming_distance(query_binary, entry.binary_code)
      similarity = 1.0 - (distance / state.bits)
      %{
        id: entry.id,
        similarity: similarity,
        metadata: entry.metadata,
        hamming_distance: distance
      }
    end)
    |> Enum.sort_by(& &1.hamming_distance)
    |> Enum.take(limit)
    
    {:ok, results}
  end
  
  @impl true
  def get_stats(state) do
    %{
      strategy: :binary,
      doc_count: state.doc_count,
      bits: state.bits,
      quantization: state.quantization,
      index_type: state.index_type
    }
  end
  
  @impl true
  def serialize(state) do
    {:ok, :erlang.term_to_binary(state)}
  end
  
  @impl true
  def deserialize(data, _opts) do
    {:ok, :erlang.binary_to_term(data)}
  end
  
  # XOR + POPCNT Hamming distance
  defp hamming_distance(binary1, binary2) when is_bitstring(binary1) and is_bitstring(binary2) do
    xor_bits(binary1, binary2, 0)
  end
  
  defp xor_bits(<<>>, <<>>, acc), do: acc
  defp xor_bits(<<a::64, rest1::bitstring>>, <<b::64, rest2::bitstring>>, acc) do
    xor_result = Bitwise.bxor(a, b)
    popcount = popcount64(xor_result)
    xor_bits(rest1, rest2, acc + popcount)
  end
  defp xor_bits(<<a::8, rest1::bitstring>>, <<b::8, rest2::bitstring>>, acc) do
    xor_result = Bitwise.bxor(a, b)
    popcount = popcount8(xor_result)
    xor_bits(rest1, rest2, acc + popcount)
  end
  defp xor_bits(<<a::1, rest1::bitstring>>, <<b::1, rest2::bitstring>>, acc) do
    xor_bits(rest1, rest2, acc + Bitwise.bxor(a, b))
  end
  
  # Population count (number of 1 bits)
  defp popcount64(x) do
    # Parallel bit counting algorithm
    x = x - (Bitwise.band(Bitwise.bsr(x, 1), 0x5555555555555555))
    x = Bitwise.band(x, 0x3333333333333333) + Bitwise.band(Bitwise.bsr(x, 2), 0x3333333333333333)
    x = Bitwise.band(x + Bitwise.bsr(x, 4), 0x0f0f0f0f0f0f0f0f)
    x = x + Bitwise.bsr(x, 8)
    x = x + Bitwise.bsr(x, 16)
    x = x + Bitwise.bsr(x, 32)
    Bitwise.band(x, 0x7f)
  end
  
  defp popcount8(x) do
    x = x - Bitwise.band(Bitwise.bsr(x, 1), 0x55)
    x = Bitwise.band(x, 0x33) + Bitwise.band(Bitwise.bsr(x, 2), 0x33)
    Bitwise.band(x + Bitwise.bsr(x, 4), 0x0f)
  end
end

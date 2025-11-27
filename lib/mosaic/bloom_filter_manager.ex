defmodule Mosaic.BloomFilterManager do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{}}
  end

  def create_bloom_filter(terms, opts \\ []) do
    size = Keyword.get(opts, :size, 10_000)
    num_hashes = Keyword.get(opts, :num_hashes, 5)
    
    bloom = BloomFilter.new(size, num_hashes)
    
    Enum.reduce(terms, bloom, fn term, acc ->
      BloomFilter.add(acc, term)
    end)
  end
end
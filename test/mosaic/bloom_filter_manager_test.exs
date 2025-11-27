defmodule Mosaic.BloomFilterManagerTest do
  use ExUnit.Case, async: true

  describe "create_bloom_filter/2" do
    test "creates bloom filter with default options" do
      terms = ["apple", "banana", "cherry"]
      bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms)
      assert %BloomFilter{} = bloom
      assert Enum.all?(terms, &BloomFilter.member?(bloom, &1))
    end

    test "creates bloom filter with custom size" do
      terms = ["one", "two"]
      bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms, size: 500)
      assert bloom.size == 500
    end

    test "creates bloom filter with custom num_hashes" do
      terms = ["test"]
      bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms, num_hashes: 3)
      assert bloom.num_hashes == 3
    end

    test "handles empty terms list" do
      bloom = Mosaic.BloomFilterManager.create_bloom_filter([])
      assert %BloomFilter{} = bloom
      refute BloomFilter.member?(bloom, "anything")
    end

    test "handles large term lists" do
      terms = Enum.map(1..1000, &"term_#{&1}")
      bloom = Mosaic.BloomFilterManager.create_bloom_filter(terms, size: 50_000)
      assert BloomFilter.member?(bloom, "term_1")
      assert BloomFilter.member?(bloom, "term_500")
      assert BloomFilter.member?(bloom, "term_1000")
    end
  end
end

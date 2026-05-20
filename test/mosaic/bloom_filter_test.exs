defmodule BloomFilterTest do
  use ExUnit.Case, async: true

  describe "new/2" do
    test "creates bloom filter with specified size and hash count" do
      bloom = BloomFilter.new(1000, 5)
      assert bloom.size == 1000
      assert bloom.num_hashes == 5
      assert :array.size(bloom.bits) == 1000
    end

    test "initializes all bits to 0" do
      bloom = BloomFilter.new(100, 3)
      all_zeros = Enum.all?(0..99, fn i -> :array.get(i, bloom.bits) == 0 end)
      assert all_zeros
    end
  end

  describe "add/2 and member?/2" do
    test "added item is a member" do
      bloom = BloomFilter.new(1000, 5)
      bloom = BloomFilter.add(bloom, "hello")
      assert BloomFilter.member?(bloom, "hello")
    end

    test "non-added item is not a member" do
      bloom = BloomFilter.new(10_000, 5)
      bloom = BloomFilter.add(bloom, "hello")
      refute BloomFilter.member?(bloom, "goodbye")
    end

    test "multiple items can be added" do
      bloom = BloomFilter.new(10_000, 5)
      items = ["apple", "banana", "cherry", "date"]
      bloom = Enum.reduce(items, bloom, &BloomFilter.add(&2, &1))
      assert Enum.all?(items, &BloomFilter.member?(bloom, &1))
    end

    test "handles various data types" do
      bloom = BloomFilter.new(10_000, 5)
      bloom = BloomFilter.add(bloom, "string")
      bloom = BloomFilter.add(bloom, 12345)
      bloom = BloomFilter.add(bloom, :atom)
      bloom = BloomFilter.add(bloom, {1, 2, 3})
      assert BloomFilter.member?(bloom, "string")
      assert BloomFilter.member?(bloom, 12345)
      assert BloomFilter.member?(bloom, :atom)
      assert BloomFilter.member?(bloom, {1, 2, 3})
    end
  end

  describe "to_binary/1 and from_binary/1" do
    test "round-trip preserves bloom filter" do
      bloom = BloomFilter.new(1000, 5)
      bloom = BloomFilter.add(bloom, "test_item")
      binary = BloomFilter.to_binary(bloom)
      restored = BloomFilter.from_binary(binary)
      assert BloomFilter.member?(restored, "test_item")
      assert restored.size == bloom.size
      assert restored.num_hashes == bloom.num_hashes
    end

    test "to_binary returns binary" do
      bloom = BloomFilter.new(100, 3)
      assert is_binary(BloomFilter.to_binary(bloom))
    end

    test "from_binary restores struct type" do
      bloom = BloomFilter.new(100, 3)
      binary = BloomFilter.to_binary(bloom)
      restored = BloomFilter.from_binary(binary)
      assert %BloomFilter{} = restored
    end
  end

  describe "false positive rate" do
    test "false positive rate is reasonable for properly sized filter" do
      bloom = BloomFilter.new(10_000, 5)
      items = Enum.map(1..100, &"item_#{&1}")
      bloom = Enum.reduce(items, bloom, &BloomFilter.add(&2, &1))
      false_positives = Enum.count(1..1000, fn i -> BloomFilter.member?(bloom, "nonexistent_#{i}") end)
      assert false_positives < 100
    end
  end
end

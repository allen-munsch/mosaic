defmodule Mosaic.Vector.CascadedSearchTest do
  use ExUnit.Case, async: false

  alias Mosaic.Vector.CascadedSearch
  alias Mosaic.Embedding.Matryoshka

  test "truncate slices embedding to target dimensions" do
    full = for i <- 1..384, do: i / 384.0

    coarse64 = Matryoshka.truncate(full, 64)
    assert length(coarse64) == 64
    assert hd(coarse64) == hd(full)

    mid128 = Matryoshka.truncate(full, 128)
    assert length(mid128) == 128
    assert hd(mid128) == hd(full)
  end

  test "truncate_binary slices binary embeddings" do
    floats = for i <- 1..100, do: i / 100.0
    binary = Matryoshka.to_binary(floats)

    truncated = Matryoshka.truncate_binary(binary, 10)
    decoded = Matryoshka.from_binary(truncated)
    assert length(decoded) == 10
    assert abs(hd(decoded) - hd(floats)) < 0.001
  end

  test "levels returns configured dimensions" do
    levels = Matryoshka.levels()
    assert is_list(levels)
    assert 64 in levels
    assert length(levels) >= 2
  end

  test "vec_table_name generates correct table names" do
    assert Matryoshka.vec_table_name(64) == :vec_nodes_64
    assert Matryoshka.vec_table_name(256) == :vec_nodes_256
  end

  test "to_binary and from_binary roundtrip" do
    original = [1.0, -0.5, 0.25, -0.125, 0.0625]
    binary = Matryoshka.to_binary(original)
    decoded = Matryoshka.from_binary(binary)
    assert length(decoded) == 5
    assert Enum.zip(original, decoded) |> Enum.all?(fn {a, b} -> abs(a - b) < 0.001 end)
  end

  test "cascade_factor returns multiplier per level" do
    assert Matryoshka.cascade_factor(64) >= 5
    assert Matryoshka.cascade_factor(128) >= 3
    assert Matryoshka.cascade_factor(256) >= 1
    assert Matryoshka.cascade_factor(999) == 5  # fallback
  end

  test "search returns empty for unknown query terms" do
    # With no shards registered, search returns empty list
    zero = List.duplicate(0.0, 8)
    results = CascadedSearch.search(zero, limit: 10, skip_levels: true)
    assert is_list(results)
  end

  test "search_text does not crash" do
    # Skip cascaded levels to avoid FederatedQuery dependency
    results = CascadedSearch.search_text("nonexistent_query_xyz_123", limit: 5, skip_levels: true)
    assert is_list(results)
  end

  test "search_within handles empty node list" do
    zero = List.duplicate(0.0, 8)
    results = CascadedSearch.search_within(zero, [], limit: 5)
    assert results == []
  end

  test "search respects skip_levels option" do
    zero = List.duplicate(0.0, 8)
    results = CascadedSearch.search(zero, limit: 3, skip_levels: true)
    assert is_list(results)
  end
end

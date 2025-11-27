defmodule VectorMathTest do
  use ExUnit.Case, async: true

  describe "norm/1" do
    test "returns correct norm for simple vector" do
      assert VectorMath.norm([3.0, 4.0]) == 5.0
    end

    test "returns 0 for zero vector" do
      assert VectorMath.norm([0.0, 0.0, 0.0]) == 0.0
    end

    test "returns 1 for unit vector" do
      assert_in_delta VectorMath.norm([1.0, 0.0, 0.0]), 1.0, 0.0001
    end

    test "handles high-dimensional vectors" do
      vector = List.duplicate(1.0, 1536)
      expected = :math.sqrt(1536)
      assert_in_delta VectorMath.norm(vector), expected, 0.0001
    end
  end

  describe "dot/2" do
    test "returns correct dot product" do
      assert VectorMath.dot([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]) == 32.0
    end

    test "returns 0 for orthogonal vectors" do
      assert VectorMath.dot([1.0, 0.0], [0.0, 1.0]) == 0.0
    end

    test "returns negative for opposite vectors" do
      assert VectorMath.dot([1.0, 0.0], [-1.0, 0.0]) < 0
    end
  end

  describe "cosine_similarity/4" do
    test "returns 1.0 for identical vectors" do
      v = [1.0, 2.0, 3.0]
      norm = VectorMath.norm(v)
      assert_in_delta VectorMath.cosine_similarity(v, norm, v, norm), 1.0, 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      v1 = [1.0, 0.0]
      v2 = [-1.0, 0.0]
      norm1 = VectorMath.norm(v1)
      norm2 = VectorMath.norm(v2)
      assert_in_delta VectorMath.cosine_similarity(v1, norm1, v2, norm2), -1.0, 0.0001
    end

    test "returns 0 for orthogonal vectors" do
      v1 = [1.0, 0.0]
      v2 = [0.0, 1.0]
      norm1 = VectorMath.norm(v1)
      norm2 = VectorMath.norm(v2)
      assert_in_delta VectorMath.cosine_similarity(v1, norm1, v2, norm2), 0.0, 0.0001
    end

    test "handles binary v2 (serialized vector)" do
      v1 = [1.0, 2.0, 3.0]
      v2 = [1.0, 2.0, 3.0]
      v2_binary = :erlang.term_to_binary(v2)
      norm1 = VectorMath.norm(v1)
      norm2 = VectorMath.norm(v2)
      assert_in_delta VectorMath.cosine_similarity(v1, norm1, v2_binary, norm2), 1.0, 0.0001
    end

    test "similarity is symmetric" do
      v1 = [1.0, 2.0, 3.0]
      v2 = [4.0, 5.0, 6.0]
      norm1 = VectorMath.norm(v1)
      norm2 = VectorMath.norm(v2)
      sim1 = VectorMath.cosine_similarity(v1, norm1, v2, norm2)
      sim2 = VectorMath.cosine_similarity(v2, norm2, v1, norm1)
      assert_in_delta sim1, sim2, 0.0001
    end

    test "magnitude does not affect similarity" do
      v1 = [1.0, 2.0, 3.0]
      v2 = [2.0, 4.0, 6.0]
      norm1 = VectorMath.norm(v1)
      norm2 = VectorMath.norm(v2)
      assert_in_delta VectorMath.cosine_similarity(v1, norm1, v2, norm2), 1.0, 0.0001
    end
  end
end

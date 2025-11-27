defmodule VectorMath do
  def cosine_similarity(v1, norm1, v2, norm2) when is_binary(v2) do
    v2_vector = :erlang.binary_to_term(v2)
    dot_product = dot(v1, v2_vector)
    dot_product / (norm1 * norm2)
  end

  def cosine_similarity(v1, norm1, v2, norm2) do
    dot_product = dot(v1, v2)
    dot_product / (norm1 * norm2)
  end

  def dot(v1, v2) do
    Enum.zip(v1, v2)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
  end

  def norm(vector) do
    vector
    |> Enum.reduce(0.0, fn x, acc -> acc + x * x end)
    |> :math.sqrt()
  end
end
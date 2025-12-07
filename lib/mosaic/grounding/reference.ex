defmodule Mosaic.Grounding.Reference do
  @moduledoc "Structured provenance for grounded retrieval"
  
  defstruct [
    :chunk_id,
    :doc_id,
    :doc_text,
    :chunk_text,
    :start_offset,
    :end_offset,
    :parent_context,
    :level
  ]
  
  def to_citation(%__MODULE__{} = ref) do
    "[#{ref.doc_id}:#{ref.start_offset}-#{ref.end_offset}]"
  end
  
  def highlighted_text(%__MODULE__{} = ref) do
    # Use binary_part for byte-based slicing
    doc_bytes = ref.doc_text
    chunk_len = ref.end_offset - ref.start_offset
    
    before = binary_part(doc_bytes, 0, ref.start_offset)
    chunk = binary_part(doc_bytes, ref.start_offset, chunk_len)
    after_text = binary_part(doc_bytes, ref.end_offset, byte_size(doc_bytes) - ref.end_offset)
    
    {before, chunk, after_text}
  end
end

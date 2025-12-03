defmodule Mosaic.Chunking.Chunk do
  @moduledoc "Represents a text chunk with provenance"
  
  @type level :: :document | :paragraph | :sentence
  
  defstruct [
    :id,
    :doc_id,
    :parent_id,
    :level,
    :text,
    :start_offset,
    :end_offset,
    :embedding
  ]
  
  def document_chunk(doc_id, text) do
    %__MODULE__{
      id: doc_id,
      doc_id: doc_id,
      parent_id: nil,
      level: :document,
      text: text,
      start_offset: 0,
      end_offset: byte_size(text)  # Changed from String.length
    }
  end
  
  def child_id(doc_id, level, start_offset) do
    "#{doc_id}:#{level_prefix(level)}:#{start_offset}"
  end
  
  defp level_prefix(:paragraph), do: "p"
  defp level_prefix(:sentence), do: "s"
  defp level_prefix(_), do: "d"
end

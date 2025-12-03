defmodule Mosaic.Chunking.Splitter do
  @moduledoc "Split text into paragraphs and sentences with offset tracking"
  
  alias Mosaic.Chunking.Chunk
  
  @paragraph_pattern ~r/\n\s*\n/
  @sentence_pattern ~r/(?<=[.!?])\s+(?=[A-Z])/
  
  def split(doc_id, text) do
    paragraphs = split_paragraphs(doc_id, text)
    sentences = Enum.flat_map(paragraphs, &split_sentences/1)
    
    %{ 
      document: Chunk.document_chunk(doc_id, text),
      paragraphs: paragraphs,
      sentences: sentences
    }
  end
  
  defp split_paragraphs(doc_id, text) do
    @paragraph_pattern
    |> Regex.split(text, include_captures: false, trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce({[], 0}, fn para_text, {acc, offset} ->
      trimmed = String.trim(para_text)
      # Guard against empty trimmed text
      if trimmed == "" do
        {acc, offset}
      else
        actual_start = find_offset(text, trimmed, offset)
        actual_end = actual_start + byte_size(trimmed)  # Use byte_size, not String.length
        
        chunk = %Chunk{
          id: Chunk.child_id(doc_id, :paragraph, actual_start),
          doc_id: doc_id,
          parent_id: doc_id,
          level: :paragraph,
          text: trimmed,
          start_offset: actual_start,
          end_offset: actual_end
        }
        
        {[chunk | acc], actual_end}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
  
  defp split_sentences(%Chunk{level: :paragraph} = para) do
    @sentence_pattern
    |> Regex.split(para.text, trim: true)
    |> Enum.reduce({[], 0}, fn sent_text, {acc, relative_offset} ->
      trimmed = String.trim(sent_text)
      if trimmed == "" do
        {acc, relative_offset}
      else
        relative_start = find_offset(para.text, trimmed, relative_offset)
        actual_start = para.start_offset + relative_start
        actual_end = actual_start + byte_size(trimmed)
        
        chunk = %Chunk{
          id: Chunk.child_id(para.doc_id, :sentence, actual_start),
          doc_id: para.doc_id,
          parent_id: para.id,
          level: :sentence,
          text: trimmed,
          start_offset: actual_start,
          end_offset: actual_end
        }
        
        {[chunk | acc], relative_start + byte_size(trimmed)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
  
  defp find_offset(_text, "", start_from), do: start_from
  defp find_offset(text, substring, start_from) when byte_size(substring) > 0 do
    scope_size = byte_size(text) - start_from
    if scope_size <= 0 do
      start_from
    else
      case :binary.match(text, substring, scope: {start_from, scope_size}) do
        {pos, _} -> pos
        :nomatch -> start_from
      end
    end
  end
end

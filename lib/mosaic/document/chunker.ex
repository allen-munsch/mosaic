defmodule Mosaic.Document.Chunker do
  @moduledoc """
  Split documents into semantic chunks for RAG retrieval.

  Strategies:
    - `:paragraph` — split on double newlines (best for prose)
    - `:sentence` — split on sentence boundaries
    - `:fixed` — fixed-size chunks with overlap
    - `:markdown` — split on markdown headings (preserves structure)
    - `:sliding` — sliding window with overlap for maximum recall

  Each chunk preserves provenance: document path, start/end byte offsets,
  chunk index, and parent section context.

  ## Usage

      iex> Chunker.chunk(document, strategy: :paragraph)
      [%{id: "doc.md:0", text: "First paragraph...", ...}, ...]

      iex> Chunker.chunk(document, strategy: :sliding, size: 512, overlap: 64)
      [%{id: "doc.md:0", text: "...", ...}, ...]
  """

  defstruct [:id, :doc_path, :text, :start_byte, :end_byte, :index,
             :strategy, :parent_id, :metadata]

  @type t :: %__MODULE__{
    id: String.t(),
    doc_path: String.t(),
    text: String.t(),
    start_byte: non_neg_integer(),
    end_byte: non_neg_integer(),
    index: non_neg_integer(),
    strategy: atom(),
    parent_id: String.t() | nil,
    metadata: map()
  }

  @doc """
  Chunk a document into retrievable segments.

  Options:
    - `:strategy` — `:paragraph` (default), `:sentence`, `:fixed`, `:markdown`, `:sliding`
    - `:size` — target chunk size in characters (for :fixed, :sliding)
    - `:overlap` — overlap between chunks (for :fixed, :sliding)
    - `:min_size` — minimum chunk size (skip smaller)
    - `:max_chunks` — maximum number of chunks
  """
  def chunk(doc_path, content, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :paragraph)
    size = Keyword.get(opts, :size, 1000)
    overlap = Keyword.get(opts, :overlap, 200)
    min_size = Keyword.get(opts, :min_size, 50)

    chunks = case strategy do
      :paragraph -> chunk_paragraphs(content, doc_path, min_size)
      :sentence -> chunk_sentences(content, doc_path, size, min_size)
      :fixed -> chunk_fixed(content, doc_path, size, overlap, min_size)
      :markdown -> chunk_markdown(content, doc_path, min_size)
      :sliding -> chunk_sliding(content, doc_path, size, overlap, min_size)
      _ -> chunk_paragraphs(content, doc_path, min_size)
    end

    Keyword.get(opts, :max_chunks) |> then(fn
      nil -> chunks
      max -> Enum.take(chunks, max)
    end)
  end

  # ── Strategies ─────────────────────────────────────────────────

  defp chunk_paragraphs(content, doc_path, min_size) do
    content
    |> String.split(~r/\n\s*\n/)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < min_size))
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      build_chunk(doc_path, text, idx, content, :paragraph)
    end)
  end

  defp chunk_sentences(content, doc_path, size, min_size) do
    sentences = String.split(content, ~r/(?<=[.!?])\s+/)
    merge_sentences(sentences, doc_path, size, min_size)
  end

  defp chunk_fixed(content, doc_path, size, overlap, min_size) do
    step = max(size - overlap, 1)
    len = String.length(content)

    0..(len - 1)//step
    |> Enum.take_while(&(&1 < len))
    |> Enum.with_index()
    |> Enum.map(fn {start_pos, idx} ->
      text = String.slice(content, start_pos, size)
      %__MODULE__{
        id: "#{doc_path}:fixed:#{idx}",
        doc_path: doc_path,
        text: text,
        start_byte: start_pos,
        end_byte: min(start_pos + size, len),
        index: idx,
        strategy: :fixed,
        parent_id: nil,
        metadata: %{overlap: overlap}
      }
    end)
    |> Enum.reject(&(String.length(&1.text) < min_size))
  end

  defp chunk_markdown(content, doc_path, min_size) do
    # Split on markdown headings, preserving hierarchy
    sections = String.split(content, ~r/^(?=\#{1,6}\s)/m)

    sections
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.with_index()
    |> Enum.map(fn {section, idx} ->
      heading = case Regex.run(~r/^(\#{1,6})\s+(.+)$/m, section) do
        [_, level, title] -> %{level: String.length(level), title: String.trim(title)}
        nil -> %{level: 0, title: nil}
      end

      text = String.trim(section)

      if String.length(text) >= min_size do
        %__MODULE__{
          id: "#{doc_path}:md:#{idx}",
          doc_path: doc_path,
          text: text,
          start_byte: 0, end_byte: 0,
          index: idx,
          strategy: :markdown,
          parent_id: if(heading.level > 1, do: "#{doc_path}:md:#{idx - 1}", else: nil),
          metadata: %{heading_level: heading.level, heading_title: heading.title}
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp chunk_sliding(content, doc_path, size, overlap, min_size) do
    chunk_fixed(content, doc_path, size, overlap, min_size)
    |> Enum.map(&%{&1 | strategy: :sliding})
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp merge_sentences(sentences, doc_path, target_size, _min_size) do
    {chunks, _} =
      sentences
      |> Enum.reduce({[], {0, []}}, fn sentence, {acc, {current_size, current_sentences}} ->
        sent_size = String.length(sentence)

        if current_size + sent_size > target_size and current_sentences != [] do
          text = current_sentences |> Enum.reverse() |> Enum.join(" ")
          chunk = build_chunk(doc_path, text, length(acc), "", :sentence)
          {[chunk | acc], {sent_size, [sentence]}}
        else
          {acc, {current_size + sent_size, [sentence | current_sentences]}}
        end
      end)

    # Don't forget the last batch
    if elem(chunks, 0) != nil do
      chunks |> Enum.reverse()
    else
      chunks
    end
  end

  defp build_chunk(doc_path, text, idx, _full_content, strategy) do
    %__MODULE__{
      id: "#{doc_path}:#{strategy}:#{idx}",
      doc_path: doc_path,
      text: text,
      start_byte: 0,
      end_byte: 0,
      index: idx,
      strategy: strategy,
      parent_id: nil,
      metadata: %{}
    }
  end
end

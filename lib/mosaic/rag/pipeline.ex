defmodule Mosaic.RAG.Pipeline do
  @moduledoc """
  End-to-end RAG (Retrieval-Augmented Generation) pipeline.

  Combines document chunking, embedding, vector search, and context
  assembly into a single call. Designed for integration with LLMs.

  ## Usage

      # Full RAG pipeline
      iex> Pipeline.retrieve(
      ...>   "What is the architecture of MosaicDB?",
      ...>   top_k: 5, expand_context: true
      ...> )
      {:ok, %{
        query: "...",
        chunks: [%{text: "...", similarity: 0.92, source: "arch.pdf"}, ...],
        context: "Combined context for LLM...",
        token_count: 1250
      }}

      # With extreme compression (handle stubs)
      iex> Pipeline.retrieve_compressed(query, top_k: 10)
      {:ok, "$rag_query_abc: Array(10) [Architecture overview, ...]"}
  """

  alias Mosaic.Vector.CascadedSearch
  alias Mosaic.HandleRegistry

  @doc """
  Retrieve relevant chunks for a query and assemble context.

  Returns chunks with similarity scores, assembled context string,
  and token count for the LLM.
  """
  def retrieve(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 5)
    expand_context = Keyword.get(opts, :expand_context, true)
    min_similarity = Keyword.get(opts, :min_similarity, 0.3)
    context_window = Keyword.get(opts, :context_window, 4000)

    # Semantic search across indexed document chunks
    results = CascadedSearch.search_text(query,
      limit: top_k,
      min_similarity: min_similarity,
      filter_type: "chunk",
      skip_levels: true
    )

    # Fallback to keyword search if vector search returns nothing
    results = if results == [] do
      words = String.split(query, " ")
      like_clauses = Enum.map_join(words, " OR ", fn _ -> "source_text LIKE ?" end)
      params = Enum.map(words, &"%#{&1}%")
      Mosaic.FederatedQuery.execute(
        "SELECT id, name, type, file_path, start_line, source_text FROM nodes WHERE type = 'chunk' AND (#{like_clauses}) LIMIT ?",
        params ++ [top_k]
      )
      |> Enum.map(fn [id, name, type, file, line, text] ->
        %{id: id, name: name, type: type, file_path: file, start_line: line,
          source_text: text, similarity: 0.5}
      end)
    else
      results
    end

    if results == [] do
      {:ok, %{query: query, chunks: [], context: "", token_count: 0}}
    else
      # Expand context around each chunk if requested
      enriched = if expand_context do
        expand_chunk_context(results)
      else
        results
      end

      # Assemble context for LLM
      context = assemble_context(enriched, context_window)
      token_count = estimate_tokens(context)

      {:ok, %{
        query: query,
        chunks: enriched,
        context: context,
        token_count: token_count
      }}
    end
  end

  @doc """
  Retrieve with extreme compression — returns handle stubs instead of full data.
  The LLM receives a compact stub (~50 tokens) instead of full chunks (~5000 tokens).

  Use with HandleRegistry.expand() when the LLM needs to see actual content.
  """
  def retrieve_compressed(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 10)

    case retrieve(query, Keyword.put(opts, :top_k, top_k)) do
      {:ok, %{chunks: []}} ->
        {:ok, "$rag_empty: Array(0) []"}

      {:ok, %{chunks: chunks}} ->
        # Store full results, return compact stub
        handle_name = "$rag_#{sanitize_query(query)}"
        stub = HandleRegistry.store(handle_name, chunks, ttl: 600)
        {:ok, stub}
    end
  end

  @doc """
  Hybrid retrieval: combine vector search + keyword search for better recall.
  """
  def retrieve_hybrid(query, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 5)

    # Vector search
    vector_results = CascadedSearch.search_text(query,
      limit: top_k * 2,
      filter_type: "chunk",
      skip_levels: true
    )

    # Keyword search on chunk text
    words = String.split(query, " ")
    like_clauses = Enum.map_join(words, " OR ", fn _ -> "source_text LIKE ?" end)
    params = Enum.map(words, &"%#{&1}%")
    keyword_results = Mosaic.FederatedQuery.execute(
      "SELECT id, name, type, file_path, start_line, source_text, properties FROM nodes WHERE type = 'chunk' AND (#{like_clauses}) LIMIT ?",
      params ++ [top_k * 2]
    )

    # Deduplicate and merge
    vector_ids = MapSet.new(vector_results, & &1.id)
    keyword_unique = Enum.reject(keyword_results, fn [id | _] -> MapSet.member?(vector_ids, id) end)
    keyword_formatted = Enum.map(keyword_unique, fn row ->
      case row do
        [id, name, type, file, line, text | _] ->
          %{id: id, name: name, type: type, file_path: file, start_line: line,
            source_text: text, similarity: 0.0}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    combined = vector_results ++ keyword_formatted |> Enum.take(top_k)
    context = assemble_context(combined, 4000)

    {:ok, %{
      query: query,
      chunks: combined,
      context: context,
      token_count: estimate_tokens(context)
    }}
  end

  # ── Context Assembly ──────────────────────────────────────────

  defp assemble_context(chunks, max_chars) do
    chunks
    |> Enum.reduce({[], 0}, fn chunk, {acc, size} ->
      text = "#{chunk.name}\nSource: #{chunk.file_path}\n#{chunk.source_text}\n\n"
      new_size = size + String.length(text)
      if new_size <= max_chars, do: {[text | acc], new_size}, else: {acc, size}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n---\n")
  end

  defp expand_chunk_context(chunks) do
    # For each chunk, fetch neighboring chunks from same document
    Enum.map(chunks, fn chunk ->
      neighbors = fetch_neighbors(chunk, 2)
      Map.put(chunk, :context, neighbors)
    end)
  end

  defp fetch_neighbors(_chunk, _window), do: []  # TODO: implement neighbor fetch

  # ── Utilities ──────────────────────────────────────────────────

  defp estimate_tokens(text) do
    # Rough estimate: 1 token ≈ 4 characters for English
    div(String.length(text), 4)
  end

  defp sanitize_query(query) do
    query
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 40)
  end
end

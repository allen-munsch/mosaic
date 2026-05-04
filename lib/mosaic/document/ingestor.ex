defmodule Mosaic.Document.Ingestor do
  @moduledoc """
  Universal document ingestion for RAG pipelines.

  Ingests documents from files, directories, S3 buckets, URLs.
  Chunks them, generates embeddings (if embedding service available),
  and stores in MosaicDB's SQLite shards with vector indices.

  ## Usage

      # Single document
      iex> Ingestor.ingest("docs/architecture.pdf")
      {:ok, %{path: "docs/architecture.pdf", chunks: 45, embeddings: 45}}

      # Directory
      iex> Ingestor.ingest_directory("docs/")
      {:ok, %{files: 12, chunks: 520, embeddings: 520}}

      # S3 bucket (prefix)
      iex> Ingestor.ingest_s3("my-bucket", "articles/2024/")
      {:ok, %{objects: 230, chunks: 12000, embeddings: 12000}}

      # URL
      iex> Ingestor.ingest_url("https://example.com/article")
      {:ok, %{url: "...", chunks: 5, embeddings: 5}}
  """

  alias Mosaic.Document.{Reader, Chunker}
  alias Mosaic.Graph.Writer
  require Logger

  @doc "Ingest a single document file."
  def ingest(path, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, detect_strategy(path))
    chunk_size = Keyword.get(opts, :chunk_size, 1000)
    embed = Keyword.get(opts, :embed, true)

    with {:ok, content, meta} <- Reader.read(path),
         chunks = Chunker.chunk(path, content,
           strategy: strategy, size: chunk_size, min_size: 50),
         {:ok, stats} <- store_chunks(chunks, path, embed) do

      {:ok, Map.merge(stats, %{path: path, format: meta[:format], size: meta[:size]})}
    end
  end

  @doc "Ingest all supported documents in a directory."
  def ingest_directory(dir, opts \\ []) do
    patterns = Keyword.get(opts, :patterns, ~w(.txt .md .pdf .docx .html .htm .rst .org .adoc .csv .log))
    parallel = Keyword.get(opts, :parallel, System.schedulers_online())

    files = dir
      |> then(&Path.wildcard(&1 <> "/**/*"))
      |> Enum.filter(fn f ->
        ext = Path.extname(f) |> String.downcase()
        ext in patterns and File.regular?(f)
      end)

    Logger.info("Ingesting #{length(files)} documents from #{dir}")

    results = files
      |> Task.async_stream(
        fn f -> ingest(f, opts) end,
        max_concurrency: parallel,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{files: 0, chunks: 0, embeddings: 0, errors: 0}, fn
        {:ok, {:ok, s}}, acc ->
          %{acc | files: acc.files + 1, chunks: acc.chunks + s.chunks, embeddings: acc.embeddings + s.embeddings}
        _, acc ->
          %{acc | errors: acc.errors + 1}
      end)

    {:ok, results}
  end

  @doc "Ingest documents from an S3 bucket prefix."
  def ingest_s3(bucket, prefix \\ "", opts \\ []) do
    # Use AWS CLI if available, or HTTP endpoint
    case System.find_executable("aws") do
      nil ->
        {:error, "AWS CLI not found. Install: pip install awscli"}

      _aws ->
        list_cmd = if prefix == "",
          do: ["s3", "ls", "s3://#{bucket}/", "--recursive"],
          else: ["s3", "ls", "s3://#{bucket}/#{prefix}", "--recursive"]

        case System.cmd("aws", list_cmd, stderr_to_stdout: true) do
          {listing, 0} ->
            keys = parse_s3_listing(listing)
            Logger.info("Found #{length(keys)} S3 objects in #{bucket}/#{prefix}")

            tmp_dir = Path.join(System.tmp_dir!(), "mosaic_s3_#{System.unique_integer([:positive])}")
            File.mkdir_p!(tmp_dir)

            results = keys
              |> Task.async_stream(
                fn key ->
                  local = Path.join(tmp_dir, String.replace(key, "/", "_"))
                  case System.cmd("aws", ["s3", "cp", "s3://#{bucket}/#{key}", local], stderr_to_stdout: true) do
                    {_, 0} -> ingest(local, opts)
                    _ -> {:error, :download_failed}
                  end
                end,
                max_concurrency: 4,
                timeout: 300_000,
                on_timeout: :kill_task
              )
              |> Enum.reduce(%{objects: 0, chunks: 0, embeddings: 0, errors: 0}, fn
                {:ok, {:ok, s}}, acc ->
                  %{acc | objects: acc.objects + 1, chunks: acc.chunks + s.chunks, embeddings: acc.embeddings + s.embeddings}
                _, acc ->
                  %{acc | errors: acc.errors + 1}
              end)

            File.rm_rf!(tmp_dir)
            {:ok, results}

          {error, _} ->
            {:error, "aws s3 ls failed: #{String.slice(error, 0, 200)}"}
        end
    end
  end

  @doc "Ingest content from a URL."
  def ingest_url(url, opts \\ []) do
    with {:ok, content, meta} <- Reader.read_url(url),
         chunks = Chunker.chunk(URI.parse(url).path || url, content,
           strategy: :paragraph, size: 1000),
         {:ok, stats} <- store_chunks(chunks, url, Keyword.get(opts, :embed, true)) do

      {:ok, Map.merge(stats, %{url: url, format: meta[:format]})}
    end
  end

  # ── Storage ────────────────────────────────────────────────────

  defp store_chunks(chunks, source_path, embed?) do
    embed_fn = if embed?, do: &generate_embeddings/1, else: fn _ -> [] end

    texts = Enum.map(chunks, & &1.text)
    embeddings = embed_fn.(texts)

    # Build nodes from chunks
    nodes = Enum.zip(chunks, pad_embeddings(embeddings, length(chunks)))
      |> Enum.map(fn {chunk, emb} ->
        %{
          id: chunk.id,
          name: String.slice(chunk.text, 0, 80),
          type: "chunk",
          language: nil,
          file_path: chunk.doc_path,
          start_line: chunk.index,
          end_line: chunk.index,
          source_text: chunk.text,
          parent_id: chunk.parent_id,
          properties: %{
            strategy: chunk.strategy,
            byte_start: chunk.start_byte,
            byte_end: chunk.end_byte,
            chunk_index: chunk.index
          },
          embedding: emb
        }
      end)

    shard = get_chunk_shard(source_path)
    unless File.exists?(shard), do: Mosaic.StorageManager.create_shard(shard)

    {:ok, stats} = Writer.write_subgraph(shard, nodes, [])

    # Register for auto-discovery
    Mosaic.ShardRouter.register_shard(%{
      id: "chunks_#{Path.basename(source_path)}",
      path: shard,
      centroids: %{document: List.duplicate(0.0, 384)},
      doc_count: stats.nodes_written,
      bloom_filter: nil
    })

    {:ok, %{chunks: stats.nodes_written, embeddings: if(embed?, do: stats.nodes_written, else: 0)}}
  end

  defp generate_embeddings(texts) do
    Mosaic.EmbeddingService.encode_batch(texts)
  rescue
    _ ->
      # Fallback: zero vectors if embedding service unavailable
      dim = Mosaic.Config.get(:embedding_dim)
      Enum.map(texts, fn _ -> List.duplicate(0.0, dim) end)
  end

  defp pad_embeddings(embeddings, count) when length(embeddings) < count do
    dim = Mosaic.Config.get(:embedding_dim)
    pad = List.duplicate(List.duplicate(0.0, dim), count - length(embeddings))
    embeddings ++ pad
  end
  defp pad_embeddings(embeddings, _count), do: embeddings

  defp get_chunk_shard(source_path) do
    storage = Mosaic.Config.get(:storage_path)
    name = source_path
      |> Path.basename()
      |> String.replace(~r/[^a-zA-Z0-9_.-]/, "_")
      |> then(&"chunks_#{&1}_#{System.os_time(:millisecond)}.db")

    Path.join(storage, name)
  end

  defp detect_strategy(path) do
    cond do
      String.ends_with?(path, ".md") -> :markdown
      String.ends_with?(path, ".html") -> :paragraph
      true -> :paragraph
    end
  end

  defp parse_s3_listing(listing) do
    listing
    |> String.split("\n")
    |> Enum.map(fn line ->
      # Format: "2024-01-15 10:30:45   12345 key/name.pdf"
      parts = String.split(line)
      if length(parts) >= 4 do
        Enum.drop(parts, 3) |> Enum.join(" ")
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
  end
end

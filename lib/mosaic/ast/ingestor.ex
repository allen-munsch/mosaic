defmodule Mosaic.AST.Ingestor do
  @moduledoc """
  Orchestrates full AST ingestion: parse → extract → embed → store.

  Ingests individual files, directories, or entire repositories into
  MosaicDB's persistent graph storage. Nodes and edges are written to
  SQLite shards in transactions. Embeddings are generated using the
  configured embedding service.

  ## Usage

      # Single file
      iex> Ingestor.ingest_file("lib/mosaic/api.ex")
      {:ok, %{file: "lib/mosaic/api.ex", nodes: 15, edges: 42, shard: "shard_1.db"}}

      # Directory
      iex> Ingestor.ingest_directory("lib/mosaic")
      {:ok, %{files: 45, nodes: 1823, edges: 5120, shards: 3, errors: 0}}

      # Repository (git-aware incremental)
      iex> Ingestor.ingest_repository("/path/to/repo")
      {:ok, %{files: 1200, nodes: 45100, edges: 123000, shards: 12}}

  ## Extension Points

  The ingestor calls Mosaic.EmbeddingService.encode_batch/1 for embeddings.
  Override via opts[:embed_fn] for custom embedding strategies.
  """

  require Logger

  alias Mosaic.AST.{Parser, SymbolExtractor, RelationshipExtractor}
  alias Mosaic.Graph.Writer

  # ── Single File ────────────────────────────────────────────────

  @doc "Ingest a single file into the graph database."
  def ingest_file(path, opts \\ []) do
    language = Keyword.get(opts, :language) || Parser.detect_language(path)

    unless language do
      {:error, "unsupported file extension: #{Path.extname(path)}"}
    else
      with {:ok, ast} <- Parser.parse_file(path, language: language, max_size: max_file_size(opts)),
           {:ok, nodes, edges} <- extract_symbols_and_edges(ast, path, language),
           {:ok, stats} <- write_to_shard(path, nodes, edges, opts) do
        {:ok, stats}
      end
    end
  end

  # ── Directory ──────────────────────────────────────────────────

  @doc "Ingest all supported files in a directory tree."
  def ingest_directory(dir, opts \\ []) do
    patterns = Keyword.get(opts, :patterns, file_patterns())
    exclude = Keyword.get(opts, :exclude, default_excludes())
    parallel = Keyword.get(opts, :parallel, System.schedulers_online())

    files = dir
      |> Path.wildcard("**/*")
      |> Enum.filter(fn f ->
        matches = Enum.any?(patterns, &String.ends_with?(f, &1))
        excluded = Enum.any?(exclude, &String.contains?(f, &1))
        matches and not excluded and File.regular?(f)
      end)
      |> Enum.sort()

    Logger.info("Ingesting #{length(files)} files from #{dir} (parallel=#{parallel})")

    results = files
      |> Task.async_stream(
        fn file -> ingest_file(file, opts) end,
        max_concurrency: parallel,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{files: 0, nodes: 0, edges: 0, errors: 0}, fn
        {:ok, {:ok, %{nodes: n, edges: e}}}, acc ->
          %{acc | files: acc.files + 1, nodes: acc.nodes + n, edges: acc.edges + e}

        {:ok, {:error, _}}, acc ->
          %{acc | files: acc.files + 1, errors: acc.errors + 1}

        {:exit, _}, acc ->
          %{acc | errors: acc.errors + 1}
      end)

    {:ok, Map.put(results, :shards, active_shard_count())}
  end

  # ── Repository (Git-Aware) ─────────────────────────────────────

  @doc "Ingest a git repository, optionally only changed files since a ref."
  def ingest_repository(repo_path, opts \\ []) do
    base_ref = Keyword.get(opts, :base_ref, "HEAD")
    incremental = Keyword.get(opts, :incremental, true)

    files =
      if incremental do
        # Only files changed since base_ref
        {changed, 0} = System.cmd("git", ["diff", "--name-only", "--diff-filter=ACM", base_ref],
          cd: repo_path)
        changed
          |> String.split("\n", trim: true)
          |> Enum.map(&Path.join(repo_path, &1))
      else
        # All files
        repo_path
          |> Path.wildcard("**/*")
          |> Enum.filter(&File.regular?/1)
      end

    Logger.info("Ingesting #{length(files)} files from repo #{repo_path} (incremental=#{incremental})")

    files
    |> Task.async_stream(
      fn file -> ingest_file(file, opts) end,
      max_concurrency: System.schedulers_online(),
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{files: 0, nodes: 0, edges: 0, errors: 0}, fn
      {:ok, {:ok, %{nodes: n, edges: e}}}, acc ->
        %{acc | files: acc.files + 1, nodes: acc.nodes + n, edges: acc.edges + e}

      {:ok, {:error, _}}, acc ->
        %{acc | files: acc.files + 1, errors: acc.errors + 1}

      {:exit, _}, acc ->
        %{acc | errors: acc.errors + 1}
    end)
    |> then(&{:ok, Map.put(&1, :shards, active_shard_count())})
  end

  # ── Source String ──────────────────────────────────────────────

  @doc "Ingest source text directly (for API/streaming use)."
  def ingest_source(source, language, file_path, opts \\ []) do
    with {:ok, ast} <- Parser.parse_string(source, language: language),
         {:ok, nodes, edges} <- extract_symbols_and_edges(ast, file_path, language),
         {:ok, stats} <- write_to_shard(file_path, nodes, edges, opts) do
      {:ok, stats}
    end
  end

  # ── Internal Pipeline ──────────────────────────────────────────

  defp extract_symbols_and_edges(ast, file_path, language) do
    nodes = SymbolExtractor.extract(ast, file_path, language)

    if Enum.empty?(nodes) do
      {:ok, [], []}
    else
      edges = RelationshipExtractor.extract(ast, nodes, file_path, language)
      {:ok, nodes, edges}
    end
  end

  defp write_to_shard(file_path, nodes, edges, opts) do
    embed_fn = Keyword.get(opts, :embed_fn, &default_embed/1)

    # Generate embeddings for nodes (batch if possible)
    nodes_with_embeddings =
      if Enum.empty?(nodes) do
        nodes
      else
        texts = Enum.map(nodes, fn n ->
          (n.source_text || n.name) |> String.slice(0, 512)
        end)

        embeddings = embed_fn.(texts)

        Enum.zip(nodes, embeddings)
        |> Enum.map(fn {node, emb} -> Map.put(node, :embedding, emb) end)
      end

    # Get or create active shard
    shard_path = get_active_shard()

    Writer.write_subgraph(shard_path, nodes_with_embeddings, edges,
      file_path: file_path
    )
  end

  # ── Embedding ──────────────────────────────────────────────────

  defp default_embed(texts) do
    Mosaic.EmbeddingService.encode_batch(texts)
  rescue
    _ ->
      # Fallback: return zero vectors if embedding service unavailable
      dim = Mosaic.Config.get(:embedding_dim)
      Enum.map(texts, fn _ -> List.duplicate(0.0, dim) end)
  end

  # ── Shard Management ───────────────────────────────────────────

  defp get_active_shard do
    # Use StorageManager to get or create the active graph shard
    storage_path = Mosaic.Config.get(:storage_path)
    shard_path = Path.join(storage_path, "graph_current.db")

    unless File.exists?(shard_path) do
      case Mosaic.StorageManager.create_shard(shard_path) do
        {:ok, ^shard_path} -> :ok
        {:error, reason} -> Logger.error("Failed to create graph shard: #{inspect(reason)}")
      end
    end

    shard_path
  end

  defp active_shard_count do
    storage_path = Mosaic.Config.get(:storage_path)

    Path.wildcard(Path.join(storage_path, "*.db"))
    |> Enum.count()
  end

  # ── Config ─────────────────────────────────────────────────────

  defp max_file_size(opts) do
    Keyword.get(opts, :max_size, Mosaic.Config.get(:ast_max_file_size_bytes))
  end

  defp file_patterns do
    [
      ".ex", ".exs", ".heex",
      ".py", ".pyi",
      ".rs",
      ".go",
      ".js", ".mjs", ".cjs", ".jsx",
      ".ts", ".tsx",
      ".java",
      ".c", ".h",
      ".cpp", ".cc", ".cxx", ".hpp",
      ".rb"
    ]
  end

  defp default_excludes do
    ~w(_build deps node_modules .git dist target __pycache__ .elixir_ls)
  end
end

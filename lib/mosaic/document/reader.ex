defmodule Mosaic.Document.Reader do
  @moduledoc """
  Read documents from various formats into plain text.

  Supported formats:
    - .txt, .md, .markdown — plain text
    - .pdf — via pdftotext (poppler-utils)
    - .docx — via unzip + XML parsing (pure Elixir)
    - .html, .htm — via basic tag stripping
    - .rst, .org, .adoc — plain text (structure preserved)

  ## Usage

      iex> Reader.read("doc.pdf")
      {:ok, "PDF content as text...", %{format: "pdf", pages: 10}}

      iex> Reader.read_batch(["doc1.md", "doc2.txt"])
      [ok: {"doc1.md", "content..."}, ok: {"doc2.txt", "content..."}]
  """

  @doc "Read a single document file to text."
  def read(path) when is_binary(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ext when ext in [".txt", ".md", ".markdown", ".rst", ".org", ".adoc", ".xml", ".json", ".yaml", ".yml", ".toml", ".csv", ".log"] ->
        read_text(path)

      ".pdf" ->
        read_pdf(path)

      ".docx" ->
        read_docx(path)

      ".html" ->
        read_html(path)

      ".htm" ->
        read_html(path)

      _ ->
        # Try as plain text
        read_text(path)
    end
  end

  @doc "Read a batch of files, returning tagged results."
  def read_batch(paths) when is_list(paths) do
    Enum.map(paths, fn path ->
      case read(path) do
        {:ok, content, meta} -> {:ok, %{path: path, content: content, meta: meta}}
        {:error, reason} -> {:error, %{path: path, reason: reason}}
      end
    end)
  end

  @doc "Read text from a URL."
  def read_url(url) do
    case Req.get(url, max_redirects: 5, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        content = if is_binary(body), do: body, else: inspect(body)
        {:ok, content, %{format: "url", url: url, size: byte_size(content)}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ── Format Readers ─────────────────────────────────────────────

  defp read_text(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content, %{format: "text", size: byte_size(content), lines: count_lines(content)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_pdf(path) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error, "pdftotext not found. Install: sudo apt install poppler-utils"}

      _pdftotext ->
        case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, output, %{format: "pdf", size: byte_size(output), lines: count_lines(output)}}

          {output, _code} ->
            # pdftotext may produce partial output even on error
            if byte_size(output) > 0 do
              {:ok, output, %{format: "pdf", size: byte_size(output), lines: count_lines(output), partial: true}}
            else
              {:error, "pdftotext failed"}
            end
        end
    end
  end

  defp read_docx(path) do
    # DOCX is a ZIP of XML files. Extract document.xml and parse text.
    case System.find_executable("unzip") do
      nil ->
        {:error, "unzip not found"}

      _unzip ->
        tmp = Path.join(System.tmp_dir!(), "mosaic_docx_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)

        try do
          case System.cmd("unzip", ["-o", path, "word/document.xml", "-d", tmp], stderr_to_stdout: true) do
            {_, 0} ->
              doc_xml = Path.join([tmp, "word", "document.xml"])
              if File.exists?(doc_xml) do
                xml = File.read!(doc_xml)
                text = extract_docx_text(xml)
                {:ok, text, %{format: "docx", size: byte_size(text), lines: count_lines(text)}}
              else
                {:error, "document.xml not found in docx"}
              end

            {output, _code} ->
              {:error, "unzip failed: #{String.slice(output, 0, 100)}"}
          end
        after
          File.rm_rf!(tmp)
        end
    end
  end

  defp read_html(path) do
    case File.read(path) do
      {:ok, content} ->
        text = strip_html(content)
        {:ok, text, %{format: "html", size: byte_size(text), lines: count_lines(text)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Text Extraction Helpers ────────────────────────────────────

  defp extract_docx_text(xml) do
    # Extract text from <w:t> tags in DOCX document.xml
    ~r/<w:t[^>]*>([^<]*)<\/w:t>/
    |> Regex.scan(xml)
    |> Enum.map(fn [_, text] -> text end)
    |> Enum.join("")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/&#\d+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # ── Utilities ──────────────────────────────────────────────────

  defp count_lines(content) do
    content |> String.split("\n") |> length()
  end
end

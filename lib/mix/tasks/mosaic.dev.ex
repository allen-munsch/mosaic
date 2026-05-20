defmodule Mix.Tasks.Mosaic.Dev do
  @moduledoc """
  Start a dev server with hot reload for .sexpr files.

  Watches .sexpr files in examples/ and auto-reifies them to
  React, Vue, and HTML whenever the source changes.

  ## Usage

      mix mosaic.dev                    # Watch examples/
      mix mosaic.dev examples/todo.sexpr  # Watch specific file

  Output goes to examples/ as:
    todo.react.jsx  — React JSX output
    todo.vue        — Vue SFC output
    todo.html       — Plain HTML output
  """

  use Mix.Task

  @shortdoc "Dev server with hot reload for S-expression reification"

  def run(args) do
    Application.ensure_all_started(:mosaic)

    dir = if args == [], do: "examples", else: hd(args)
    pattern = if File.dir?(dir), do: Path.join(dir, "*.sexpr"), else: dir

    IO.puts("🔍 Watching: #{pattern}")
    IO.puts("   Reifying to: React (.react.jsx), Vue (.vue), HTML (.html)")
    IO.puts("")

    # Initial build
    reify_all(pattern)

    # Watch for changes (poll-based, works everywhere)
    watch_loop(pattern)
  end

  defp reify_all(pattern) do
    Path.wildcard(pattern)
    |> Enum.each(&reify_file/1)
  end

  defp reify_file(sexpr_path) do
    base = Path.rootname(sexpr_path)

    case File.read(sexpr_path) do
      {:ok, source} ->
        # React
        case Mosaic.Reify.transpile(source, :react) do
          {:ok, react_code} ->
            File.write!("#{base}.react.jsx", react_code)
            IO.puts("  ✅ #{Path.basename(base)}.react.jsx")

          {:error, r} ->
            IO.puts("  ❌ React: #{inspect(r)}")
        end

        # Vue
        case Mosaic.Reify.transpile(source, :vue,
               component_name: Path.basename(base) |> Macro.camelize()) do
          {:ok, vue_code} ->
            File.write!("#{base}.vue", vue_code)
            IO.puts("  ✅ #{Path.basename(base)}.vue")

          {:error, r} ->
            IO.puts("  ❌ Vue: #{inspect(r)}")
        end

        # HTML
        case Mosaic.Reify.transpile(source, :html) do
          {:ok, html_code} ->
            File.write!("#{base}.html", html_code)
            IO.puts("  ✅ #{Path.basename(base)}.html")

          {:error, r} ->
            IO.puts("  ❌ HTML: #{inspect(r)}")
        end

      {:error, r} ->
        IO.puts("  ❌ Read error: #{inspect(r)}")
    end
  end

  defp watch_loop(pattern) do
    # Poll every 1 second for changes
    mtimes = get_mtimes(pattern)

    Process.sleep(1000)

    new_mtimes = get_mtimes(pattern)

    changed = Map.keys(new_mtimes)
      |> Enum.filter(fn path ->
        Map.get(new_mtimes, path) != Map.get(mtimes, path)
      end)

    unless Enum.empty?(changed) do
      IO.puts("")
      IO.puts("[#{Time.utc_now() |> Time.truncate(:second)}] Detected changes:")
      Enum.each(changed, fn path ->
        IO.puts("  📝 #{Path.basename(path)}")
        reify_file(path)
      end)
    end

    watch_loop(pattern)
  end

  defp get_mtimes(pattern) do
    Path.wildcard(pattern)
    |> Map.new(fn path -> {path, File.stat!(path).mtime} end)
  end
end

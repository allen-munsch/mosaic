# MosaicDB Benchmark Suite
#
# Usage:
#   mix run benches/run.exs
#   mix run benches/run.exs -- --compare
#
# Results written to benches/results/

alias Mosaic.Benchmarks

compare_mode = "--compare" in System.argv()

if compare_mode do
  IO.puts("=== MosaicDB Competitive Comparison ===")
  comparison = Benchmarks.compare()
  path = Path.join(File.cwd!(), "benches/results/comparison_#{DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")}.json")
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, Jason.encode!(comparison, pretty: true))

  IO.puts("")
  IO.puts("Competitor Comparison Matrix:")
  IO.puts("─────────────────────────────")
  Enum.each(comparison.comparisons, fn c ->
    winner = if c.mosaic_wins == true, do: " ✅ MOSAIC", else: if c.mosaic_wins == false, do: " ❌", else: " —"
    IO.puts("  #{c.metric}#{winner}")
  end)
  IO.puts("")
  IO.puts("Results saved to: #{path}")
else
  IO.puts("=== MosaicDB Benchmark Suite ===")
  IO.puts("System: #{Benchmarks.system_info().os}, #{Benchmarks.system_info().cpu_cores} cores, #{Benchmarks.system_info().memory_gb}GB RAM")
  IO.puts("")

  {:ok, report} = Benchmarks.run_all()

  Enum.each(report.benchmarks, fn b ->
    IO.puts("#{b.benchmark} (#{b.elapsed_ms}ms)")
    IO.puts("  #{String.pad_trailing("", 60, "-")}")
    format_result(b.result)
    IO.puts("")
  end)

  IO.puts("Results saved to benches/results/")
end

defp format_result(%{results: results}) when is_list(results) do
  Enum.each(Enum.take(results, 5), fn r ->
    IO.puts("  #{inspect(Map.drop(r, [:results]))}")
  end)
  if length(results) > 5 do
    IO.puts("  ... (#{length(results) - 5} more)")
  end
end

defp format_result(result) do
  IO.puts("  #{inspect(result)}")
end

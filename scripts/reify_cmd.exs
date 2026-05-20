Application.ensure_all_started(:mosaic)

[input, fw] = System.argv()
sexpr = if File.exists?(input), do: File.read!(input), else: input
fw_atom = String.to_atom(fw)

case Mosaic.Reify.transpile(sexpr, fw_atom) do
  {:ok, code} -> IO.puts(code)
  {:error, r} -> IO.puts("Error: #{inspect(r)}")
end

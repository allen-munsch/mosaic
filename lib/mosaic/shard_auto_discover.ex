defmodule Mosaic.ShardAutoDiscover do
  @moduledoc """
  Scans storage directory for existing shard files and registers them
  with the ShardRouter. Called on startup so that scripts running in
  separate processes can find previously-indexed data.
  """

  def discover do
    storage = Mosaic.Config.get(:storage_path)

    if File.dir?(storage) do
      Path.wildcard(Path.join(storage, "*.db"))
      |> Enum.each(fn shard_path ->
        case Mosaic.ConnectionPool.checkout(shard_path) do
          {:ok, conn} ->
            has_nodes = case Mosaic.DB.query_one(conn, "SELECT COUNT(*) FROM nodes") do
              {:ok, count} when is_integer(count) and count > 0 -> true
              {:ok, count} when is_binary(count) ->
                {n, _} = Integer.parse(count); n > 0
              _ -> false
            end
            Mosaic.ConnectionPool.checkin(shard_path, conn)

            if has_nodes do
              Mosaic.ShardRouter.register_shard(%{
                id: Path.basename(shard_path, ".db"),
                path: shard_path,
                centroids: %{document: List.duplicate(0.0, 384)},
                doc_count: 1,
                bloom_filter: nil
              })
              IO.puts("  Discovered shard: #{Path.basename(shard_path)}")
            end
          _ -> :skip
        end
      end)
    end
  end
end

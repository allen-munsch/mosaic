defmodule Mosaic.Graph.ShardStrategy do
  @moduledoc """
  Package-boundary shard routing for the code graph.

  Routes nodes to shards based on file_path prefix (package/module
  boundary). Keeps connected subgraphs co-located when possible.
  Uses bloom filters for edge existence checks across shards.

  ## Strategy

    1. Parse file_path to extract package prefix (first directory component)
    2. Map package → shard using consistent hashing
    3. Nodes in the same package go to the same shard
    4. Cross-package edges link shards — handled by FederatedTraversal

  ## Configuration

      config :mosaic,
        graph_shard_strategy: :package,  # or :hash, :round_robin
        graph_max_nodes_per_shard: 50_000,
        graph_prefer_co_location: true
  """

  require Logger

  @doc "Route a node to its target shard based on file_path."
  def route_node(%{file_path: file_path}) when is_binary(file_path) do
    package = extract_package(file_path)
    shard_path = shard_for_package(package, file_path)
    shard_path
  end

  def route_node(%{"file_path" => file_path}) when is_binary(file_path) do
    route_node(%{file_path: file_path})
  end

  def route_node(_node) do
    # Fallback: default shard
    default_shard()
  end

  @doc "Route a batch of nodes, grouping by package for co-location."
  def route_batch(nodes) do
    nodes
    |> Enum.group_by(&extract_package(Map.get(&1, :file_path) || Map.get(&1, "file_path", "")))
    |> Enum.map(fn {package, package_nodes} ->
      {shard_for_package(package, hd(package_nodes)), package_nodes}
    end)
  end

  @doc "List all packages and their shard assignments."
  def package_map do
    storage_path = Mosaic.Config.get(:storage_path)

    Path.wildcard(Path.join(storage_path, "*.db"))
    |> Enum.reduce(%{}, fn shard_path, acc ->
      case read_package_manifest(shard_path) do
        {:ok, packages} ->
          Enum.reduce(packages, acc, fn pkg, a -> Map.put(a, pkg, shard_path) end)
        _ -> acc
      end
    end)
  end

  @doc "Find which shard a package lives in."
  def lookup_package(package) do
    package_map()[package]
  end

  @doc "Check if a shard is nearing capacity and should be rotated."
  def should_rotate?(shard_path) do
    max_nodes = Mosaic.Config.get(:graph_max_nodes_per_shard, 50_000)

    case get_node_count(shard_path) do
      {:ok, count} when count >= max_nodes -> {:rotate, count}
      {:ok, count} -> {:ok, count}
      _ -> {:ok, 0}
    end
  end

  @doc "Create a new shard for overflow from a full shard."
  def create_overflow_shard(_full_shard_path) do
    storage_path = Mosaic.Config.get(:storage_path)
    shard_id = "overflow_#{System.os_time(:millisecond)}_#{:rand.uniform(1000)}"
    shard_path = Path.join(storage_path, "#{shard_id}.db")

    case Mosaic.StorageManager.create_shard(shard_path) do
      {:ok, ^shard_path} ->
        Logger.info("Created overflow shard: #{shard_path}")
        {:ok, shard_path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Bloom Filter for Cross-Shard Edge Checks ──────────────────

  @doc "Build a bloom filter of edge endpoints in a shard for fast cross-shard checks."
  def build_edge_bloom(shard_path) do
    with {:ok, conn} <- Mosaic.ConnectionPool.checkout(shard_path) do
      {:ok, rows} = Mosaic.DB.query(conn, "SELECT source_id, target_id FROM edges")

      items = rows |> Enum.flat_map(fn [src, tgt] -> [src, tgt] end)
      item_count = length(items)

      # Create bloom filter with ~1% false positive rate
      filter =
        BloomFilter.new(item_count * 10, 7)
        |> then(fn b -> Enum.reduce(items, b, &BloomFilter.add(&2, &1)) end)

      Mosaic.ConnectionPool.checkin(shard_path, conn)
      {:ok, filter}
    end
  end

  @doc "Check if an edge endpoint MIGHT exist in a shard (bloom filter, false positives OK)."
  def might_contain?(bloom_filter, node_id) do
    BloomFilter.member?(bloom_filter, node_id)
  end

  # ── Private ────────────────────────────────────────────────────

  defp extract_package(file_path) when is_binary(file_path) and file_path != "" do
    file_path
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "_root"
      [single] -> single
      [pkg | _] -> pkg
    end
  end

  defp extract_package(_), do: "_root"

  defp shard_for_package(package, _hint_node) do
    # Consistent hash for package → shard assignment
    storage_path = Mosaic.Config.get(:storage_path)
    shard_index = :erlang.phash2(package, 256)

    # Check if a shard for this package already exists
    case lookup_package(package) do
      nil ->
        # New package — assign to a shard slot
        Path.join(storage_path, "pkg_#{rem(shard_index, 64)}.db")

      existing_path ->
        # Check capacity
        case should_rotate?(existing_path) do
          {:rotate, _} ->
            new_path = create_overflow_path(storage_path, shard_index)
            Logger.info("Rotating shard for #{package}: #{existing_path} → #{new_path}")
            new_path
          _ ->
            existing_path
        end
    end
  end

  defp default_shard do
    storage_path = Mosaic.Config.get(:storage_path)
    Path.join(storage_path, "graph_default.db")
  end

  defp create_overflow_path(storage_path, base_index) do
    suffix = System.os_time(:millisecond)
    Path.join(storage_path, "pkg_#{rem(base_index, 64)}_#{suffix}.db")
  end

  defp get_node_count(shard_path) do
    case Mosaic.ConnectionPool.checkout(shard_path) do
      {:ok, conn} ->
        result =
          case Mosaic.DB.query_one(conn, "SELECT COUNT(*) FROM nodes") do
            {:ok, count} when is_integer(count) -> {:ok, count}
            {:ok, count} when is_binary(count) -> {:ok, String.to_integer(count)}
            {:ok, nil} -> {:ok, 0}
            err -> err
          end

        Mosaic.ConnectionPool.checkin(shard_path, conn)
        result

      {:error, _} = err ->
        err
    end
  end

  defp read_package_manifest(shard_path) do
    case Mosaic.ConnectionPool.checkout(shard_path) do
      {:ok, conn} ->
        result = Mosaic.DB.query(conn, "SELECT DISTINCT file_path FROM nodes LIMIT 5000")

        Mosaic.ConnectionPool.checkin(shard_path, conn)

        case result do
          {:ok, rows} ->
            packages =
              rows
              |> Enum.map(fn [path] -> extract_package(path) end)
              |> Enum.uniq()

            {:ok, packages}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end
end

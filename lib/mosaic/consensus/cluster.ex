defmodule Mosaic.Consensus.Cluster do
  @moduledoc """
  Distributed consensus layer using :ra (Raft) for metadata coordination.

  Replaces the Hobbes VSR simulator with production-grade Raft consensus.
  Provides strongly consistent configuration, shard topology, and handle
  registry state across all nodes in the cluster.

  ## Architecture

      Node-1 (Raft leader)    Node-2 (follower)     Node-3 (follower)
      ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
      │  MosaicDB App    │   │  MosaicDB App    │   │  MosaicDB App    │
      │  :ra_server      │──▶│  :ra_server      │──▶│  :ra_server      │
      │  (leader)        │   │  (follower)      │   │  (follower)      │
      │  SQLite shards   │   │  SQLite shards   │   │  SQLite shards   │
      └──────────────────┘   └──────────────────┘   └──────────────────┘

  ## Usage

      # Write config (leader only)
      Mosaic.Consensus.Cluster.write_config("shard_topology", topology_json)

      # Read config (any node, strongly consistent)
      {:ok, topology} = Mosaic.Consensus.Cluster.read_config("shard_topology")

      # Register a new shard
      Mosaic.Consensus.Cluster.register_shard("shard_001.db", node_id())

      # Get all registered shards
      shards = Mosaic.Consensus.Cluster.list_shards()
  """

  @system :default
  @cluster_name :mosaic_consensus

  # ── Public API ─────────────────────────────────────────────

  @doc "Start the Raft cluster on this node."
  def start_cluster(_opts \\ []) do
    with :ok <- ensure_ra_started() do
      start_cluster_for_peers()
    end
  end

  defp start_cluster_for_peers do
    case Mosaic.Config.get(:cluster_peers) do
      peers when is_list(peers) and length(peers) > 0 ->
        if List.first(peers) == node() do
          case :ra.start_cluster(@system, @cluster_name, machine_conf(), server_ids(peers)) do
            {:ok, _, _} -> :ok
            {:error, :cluster_not_formed} -> join_existing()
            other -> other
          end
        else
          join_existing()
        end

      _ ->
        case :ra.start_server(@system, server_config()) do
          :ok -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> other
        end
    end
  end

  @doc "Join an existing Raft cluster."
  def join_existing do
    with :ok <- ensure_ra_started() do
      do_join_existing()
    end
  end

  defp do_join_existing do
    case :ra.start_server(@system, server_config()) do
      :ok ->
        # Trigger membership if there are peers
        peers = configured_peers()
        Enum.each(peers, fn peer ->
          if peer != node() do
            :ra.add_member(server_id(), {@cluster_name, peer})
          end
        end)
        :ok

      {:error, {:already_started, _}} -> :ok
      other -> other
    end
  end

  @doc "Write a configuration value (strongly consistent)."
  def write_config(key, value) when is_binary(key) do
    case :ra.process_command(server_id(), {:write, key, value}) do
      {:ok, _, _} -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc "Read a configuration value (strongly consistent)."
  def read_config(key) when is_binary(key) do
    # Use consistent query for strong reads
    case :ra.consistent_query(server_id(), fn state ->
      Map.get(state, key)
    end) do
      {:ok, value, _} -> {:ok, value}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc "Register a shard in the cluster topology."
  def register_shard(shard_path, node_id \\ nil) do
    node_id = node_id || node()
    with {:ok, topology} <- read_config("shard_topology") do
      topology = case topology do
        nil -> %{}
        t when is_map(t) -> t
      end
      new_topology = Map.put(topology, shard_path, %{
        node: node_id,
        registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      write_config("shard_topology", new_topology)
    end
  end

  @doc "List all registered shards."
  def list_shards do
    with {:ok, topology} <- read_config("shard_topology") do
      case topology do
        nil -> {:ok, []}
        t when is_map(t) -> {:ok, Map.to_list(t)}
      end
    end
  end

  @doc "Store a handle (token-efficient result stub) consistently."
  def store_handle(handle_name, handle_data) do
    with {:ok, handles} <- read_config("handles") do
      handles = case handles do
        nil -> %{}
        h when is_map(h) -> h
      end
      new_handles = Map.put(handles, handle_name, handle_data)
      write_config("handles", new_handles)
    end
  end

  @doc "Get the current cluster leader."
  def leader do
    case :ra.consistent_query(server_id(), fn _ -> :ok end) do
      {:ok, _, leader} -> {:ok, leader}
      other -> other
    end
  end

  @doc "Check if this node is the leader."
  def leader? do
    case leader() do
      {:ok, {_name, leader_node}} -> leader_node == node()
      _ -> false
    end
  end

  @doc "Get cluster members."
  def members do
    case :ra.members(server_id()) do
      {:ok, members, _} -> {:ok, members}
      other -> other
    end
  end

  # ── :ra Machine Callbacks ──────────────────────────────────

  @doc false
  def init(_config), do: %{}

  @doc false
  def apply(_meta, {:write, key, value}, state) do
    {Map.put(state, key, value), :ok, []}
  end

  @doc false
  def apply(_meta, {:delete, key}, state) do
    {Map.delete(state, key), :ok, []}
  end

  # ── Private ────────────────────────────────────────────────

  defp ensure_ra_started do
    case Application.ensure_all_started(:ra) do
      {:ok, _} -> ensure_default_system()
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_default_system do
    case :ra_system.fetch(@system) do
      :undefined ->
        case :ra_system.start_default() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
          other -> other
        end

      _config ->
        :ok
    end
  end

  defp machine_conf do
    {:module, __MODULE__, %{}}
  end

  defp server_config do
    id = server_id()
    uid = uid()

    %{
      id: id,
      uid: uid,
      cluster_name: @cluster_name,
      log_init_args: %{uid: uid},
      initial_members: server_ids(configured_peers()),
      machine: machine_conf()
    }
  end

  defp server_id do
    {@cluster_name, node()}
  end

  defp server_ids(nodes) do
    Enum.map(nodes, &{@cluster_name, &1})
  end

  # Stable across restarts so the server can recover its persisted log.
  defp uid do
    digest = :crypto.hash(:sha256, "#{@cluster_name}:#{node()}")
    Base.url_encode64(digest, padding: false)
  end

  defp configured_peers do
    case Mosaic.Config.get(:cluster_peers) do
      peers when is_list(peers) and length(peers) > 0 -> peers
      _ -> [node()]
    end
  end
end

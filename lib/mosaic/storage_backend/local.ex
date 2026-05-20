defmodule Mosaic.StorageBackend.Local do
  @moduledoc """
  Local filesystem storage backend.

  All operations are no-ops or local file copies. This is the default backend
  and requires no external services.
  """

  @behaviour Mosaic.StorageBackend

  require Logger

  @impl true
  def put(key, local_path) do
    remote_path = Path.join([storage_root(), key])
    File.mkdir_p!(Path.dirname(remote_path))
    File.cp!(local_path, remote_path)
    Logger.debug("StorageBackend.Local: stored #{key}")
    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def get(key, local_path) do
    remote_path = Path.join([storage_root(), key])

    if File.exists?(remote_path) do
      File.mkdir_p!(Path.dirname(local_path))
      File.cp!(remote_path, local_path)
      Logger.debug("StorageBackend.Local: retrieved #{key}")
      :ok
    else
      {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    remote_path = Path.join([storage_root(), key])
    if File.exists?(remote_path), do: File.rm!(remote_path)
    :ok
  end

  @impl true
  def list(prefix) do
    root = Path.join([storage_root(), prefix])
    if File.dir?(root) do
      Path.wildcard(Path.join(root, "**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, storage_root()))
      |> then(&{:ok, &1})
    else
      {:ok, []}
    end
  end

  @impl true
  def exists?(key) do
    File.exists?(Path.join([storage_root(), key]))
  end

  defp storage_root do
    Mosaic.Config.get(:remote_storage_path, Path.join(Mosaic.Config.get(:storage_path), "_remote"))
  end
end

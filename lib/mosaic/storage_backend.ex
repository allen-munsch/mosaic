defmodule Mosaic.StorageBackend do
  @moduledoc """
  Behaviour for pluggable shard storage backends.

  MosaicDB stores SQLite shards as files. This behaviour abstracts the
  underlying storage, enabling local filesystem, S3-compatible object storage
  (AWS S3, MinIO, GCS via S3 API), or custom backends.

  ## Backends

    * `Mosaic.StorageBackend.Local` — local filesystem (default)
    * `Mosaic.StorageBackend.S3` — S3-compatible object storage

  ## Configuration

      config :mosaic,
        storage_backend: Mosaic.StorageBackend.Local,
        storage_backend_opts: []

      # For S3/MinIO:
      config :mosaic,
        storage_backend: Mosaic.StorageBackend.S3,
        storage_backend_opts: [
          bucket: "mosaic-shards",
          endpoint: "http://minio:9000",
          access_key: "minioadmin",
          secret_key: "minioadmin",
          region: "us-east-1"
        ]

  ## Usage

      iex> backend = Mosaic.StorageBackend.get()
      iex> backend.put("shards/codebase.db", "/tmp/mosaic/shards/codebase.db")
      :ok
      iex> backend.get("shards/codebase.db", "/tmp/mosaic/shards/codebase.db")
      :ok
  """

  @doc "Store a local file to remote storage under the given key."
  @callback put(key :: String.t(), local_path :: String.t()) :: :ok | {:error, term()}

  @doc "Retrieve a file from remote storage to a local path."
  @callback get(key :: String.t(), local_path :: String.t()) :: :ok | {:error, term()}

  @doc "Delete a file from remote storage."
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @doc "List all keys under a prefix."
  @callback list(prefix :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Check if a key exists in remote storage."
  @callback exists?(key :: String.t()) :: boolean()

  @doc "Get the configured backend."
  def get do
    Mosaic.Config.get(:storage_backend, Mosaic.StorageBackend.Local)
  end

  @doc "Get backend options."
  def opts do
    Mosaic.Config.get(:storage_backend_opts, [])
  end
end

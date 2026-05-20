defmodule Mosaic.StorageBackend.S3 do
  @moduledoc """
  S3-compatible object storage backend.

  Works with AWS S3, SeaweedFS, Cloudflare R2, Backblaze B2, Garage,
  and any S3-compatible service. Uses HTTP directly (no AWS SDK dependency).

  ## Configuration

      config :mosaic,
        storage_backend: Mosaic.StorageBackend.S3,
        storage_backend_opts: [
          bucket: "mosaic-shards",
          endpoint: "http://localhost:9000",
          access_key: "any",
          secret_key: "any",
          region: "us-east-1"
        ]

  ## Local dev with SeaweedFS

      docker compose --profile s3 up -d
      # SeaweedFS starts on :9000, no auth needed for local dev
  """

  @behaviour Mosaic.StorageBackend

  require Logger

  @impl true
  def put(key, local_path) do
    with {:ok, body} <- File.read(local_path),
         :ok <- s3_put(key, body) do
      Logger.debug("StorageBackend.S3: stored #{key}")
      :ok
    end
  end

  @impl true
  def get(key, local_path) do
    with {:ok, body} <- s3_get(key) do
      File.mkdir_p!(Path.dirname(local_path))
      File.write!(local_path, body)
      Logger.debug("StorageBackend.S3: retrieved #{key}")
      :ok
    end
  end

  @impl true
  def delete(key) do
    s3_delete(key)
  end

  @impl true
  def list(prefix) do
    s3_list(prefix)
  end

  @impl true
  def exists?(key) do
    case s3_head(key) do
      :ok -> true
      _ -> false
    end
  end

  # ── S3 HTTP Operations ────────────────────────────────────

  defp s3_put(key, body) do
    url = object_url(key)
    date = amz_date()

    request = Req.new(
      method: :put,
      url: url,
      body: body,
      headers: auth_headers("PUT", key, body, date)
    )

    case Req.request(request) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_get(key) do
    url = object_url(key)
    date = amz_date()

    request = Req.new(
      method: :get,
      url: url,
      headers: auth_headers("GET", key, "", date)
    )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_delete(key) do
    url = object_url(key)
    date = amz_date()

    request = Req.new(
      method: :delete,
      url: url,
      headers: auth_headers("DELETE", key, "", date)
    )

    case Req.request(request) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_head(key) do
    url = object_url(key)
    date = amz_date()

    request = Req.new(
      method: :head,
      url: url,
      headers: auth_headers("HEAD", key, "", date)
    )

    case Req.request(request) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp s3_list(prefix) do
    url = list_url(prefix)
    date = amz_date()

    request = Req.new(
      method: :get,
      url: url,
      headers: auth_headers("GET", "", "", date)
    )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} ->
        keys = parse_list_response(body)
        {:ok, keys}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── URL construction ──────────────────────────────────────

  defp object_url(key) do
    "#{endpoint()}/#{bucket()}/#{key}"
  end

  defp list_url(prefix) do
    url = "#{endpoint()}/#{bucket()}?list-type=2"
    if prefix != "", do: url <> "&prefix=#{URI.encode(prefix)}", else: url
  end

  # ── AWS Signature V4 ──────────────────────────────────────

  defp auth_headers(method, key, body, date) do
    content_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    payload_hash = if method in ["GET", "HEAD", "DELETE"], do: "UNSIGNED-PAYLOAD", else: content_hash
    scope = "#{date |> String.slice(0, 8)}/#{region()}/s3/aws4_request"
    canonical = canonical_request(method, key, payload_hash, date)
    string_to_sign = "AWS4-HMAC-SHA256\n#{date}\n#{scope}\n#{:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)}"
    signature = sign(string_to_sign, date)

    authorization = "AWS4-HMAC-SHA256 Credential=#{access_key()}/#{scope}, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=#{signature}"

    %{
      "host" => host(),
      "x-amz-content-sha256" => payload_hash,
      "x-amz-date" => date,
      "authorization" => authorization
    }
  end

  defp canonical_request(method, key, payload_hash, date) do
    path = "/#{bucket()}/#{key}"
    query = ""
    headers = "host:#{host()}\nx-amz-content-sha256:#{payload_hash}\nx-amz-date:#{date}\n"
    signed = "host;x-amz-content-sha256;x-amz-date"
    "#{method}\n#{path}\n#{query}\n#{headers}\n#{signed}\n#{payload_hash}"
  end

  defp sign(string_to_sign, date) do
    date_key = hmac("AWS4#{secret_key()}", String.slice(date, 0, 8))
    region_key = hmac(date_key, region())
    service_key = hmac(region_key, "s3")
    signing_key = hmac(service_key, "aws4_request")
    hmac_hex(signing_key, string_to_sign)
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hmac_hex(key, data), do: :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)

  defp parse_list_response(body) do
    # Simple XML parsing for ListObjectsV2 response
    # Full XML parsing would need a library; this regex approach works for the basic case
    Regex.scan(~r/<Key>([^<]+)<\/Key>/, body)
    |> Enum.map(fn [_, key] -> key end)
  end

  # ── Configuration helpers ─────────────────────────────────

  defp bucket, do: Keyword.fetch!(opts(), :bucket)
  defp endpoint, do: Keyword.get(opts(), :endpoint, "https://s3.amazonaws.com")
  defp access_key, do: Keyword.fetch!(opts(), :access_key)
  defp secret_key, do: Keyword.fetch!(opts(), :secret_key)
  defp region, do: Keyword.get(opts(), :region, "us-east-1")
  defp opts, do: Mosaic.StorageBackend.opts()

  defp host do
    uri = URI.parse(endpoint())
    if uri.port && uri.port != 443 && uri.port != 80 do
      "#{uri.host}:#{uri.port}"
    else
      uri.host
    end
  end

  defp amz_date do
    now = DateTime.utc_now()
    Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
  end
end

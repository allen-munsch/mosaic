defmodule Mosaic.Fabric.Sandbox do
  @moduledoc """
  HTTP client for Zypi's agent sandbox executor API.

  Zypi provides OCI-compliant microVM execution via Firecracker (or QEMU/Hyper-V/Virt.framework).
  This module wraps Zypi's REST API so MosaicDB's MCP tools can provision sandboxes,
  execute commands, manage sessions, and store results in the fabric memory.

  Zypi endpoints used:
    POST /exec                    — One-shot command execution
    POST /sessions                — Create a long-lived sandbox session
    POST /sessions/:id/exec       — Execute in an existing session
    GET  /sessions/:id            — Session details
    GET  /sessions                — List all sessions
    DELETE /sessions/:id          — Close and destroy session
    GET  /sessions/stats          — Session statistics
    POST /images/:ref/warm        — Pre-warm VMs for an image
    GET  /images/:ref/warm-status — Warm VM count for image
    GET  /pool/stats              — VM pool statistics

  ## Configuration

      config :mosaic, :fabric,
        sandbox_url: "http://localhost:4000",
        enabled: true

  When disabled, fabric tools return a clear "sandbox not configured" error.
  """

  require Logger

  @doc "Check if the Zypi sandbox backend is configured and reachable."
  def available? do
    url = sandbox_url()
    url != nil and health_check(url) == :ok
  end

  @doc "Run a one-shot command in a microVM sandbox."
  def run(cmd, opts \\ []) do
    image = Keyword.get(opts, :image, "ubuntu:24.04")
    agent_id = Keyword.get(opts, :agent_id)
    env = Keyword.get(opts, :env, %{})
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 30)
    files = Keyword.get(opts, :files, %{})

    body = %{
      cmd: cmd,
      image: image,
      agent_id: agent_id,
      env: env,
      workdir: workdir,
      timeout: timeout,
      files: files
    } |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case post("/exec", body) do
      {:ok, %{"exit_code" => code} = result} ->
        {:ok,
         %{
           exit_code: code,
           stdout: result["stdout"] || "",
           stderr: result["stderr"] || "",
           duration_ms: result["duration_ms"],
           container_id: result["container_id"],
           agent_id: result["agent_id"],
           timed_out: result["timed_out"] || false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Create a long-lived sandbox session via Zypi's session API."
  def session_create(image \\ "ubuntu:24.04", opts \\ []) do
    body = %{
      image: image,
      agent_id: Keyword.get(opts, :agent_id),
      vcpus: Keyword.get(opts, :vcpus, 1),
      memory_mb: Keyword.get(opts, :memory_mb, 256),
      metadata: Keyword.get(opts, :metadata, %{})
    } |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case post("/sessions", body) do
      {:ok, %{"session_id" => session_id} = resp} ->
        {:ok,
         %{
           session_id: session_id,
           container_id: resp["container_id"],
           ip: resp["ip"],
           image: resp["image"] || image,
           agent_id: resp["agent_id"],
           status: resp["status"],
           created_at: resp["created_at"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Execute a command in an existing sandbox session."
  def session_exec(session_id, cmd, opts \\ []) do
    body = %{
      cmd: cmd,
      env: Keyword.get(opts, :env, %{}),
      workdir: Keyword.get(opts, :workdir),
      timeout: Keyword.get(opts, :timeout, 30)
    } |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case post("/sessions/#{session_id}/exec", body) do
      {:ok, %{"exit_code" => code} = result} ->
        {:ok,
         %{
           exit_code: code,
           stdout: result["stdout"] || "",
           stderr: result["stderr"] || "",
           timed_out: result["timed_out"] || false,
           session_id: result["session_id"],
           container_id: result["container_id"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Close and destroy a sandbox session."
  def session_close(session_id) do
    delete("/sessions/#{session_id}")
    :ok
  end

  @doc "Get VM pool statistics from Zypi."
  def pool_stats do
    case get("/pool/stats") do
      {:ok, stats} -> {:ok, stats}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Request pre-warming of VMs for a specific image."
  def warm_image(image_ref, count \\ 1) do
    post("/images/#{image_ref}/warm", %{count: min(count, 10)})
  end

  @doc "Check how many warm VMs exist for an image."
  def warm_status(image_ref) do
    get("/images/#{image_ref}/warm-status")
  end

  @doc "Get session statistics."
  def session_stats do
    get("/sessions/stats")
  end

  @doc "List all active sessions."
  def list_sessions do
    get("/sessions")
  end

  # ── HTTP Helpers ──────────────────────────────────────────────

  defp post(path, body) do
    url = sandbox_url() <> path
    json = Jason.encode!(body)

    case Req.post(url, body: json, headers: [{"content-type", "application/json"}],
                  receive_timeout: 60_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_body(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Zypi API error #{status}: #{inspect(body)}")
        {:error, "Zypi returned HTTP #{status}: #{truncate(inspect(body), 200)}"}

      {:error, %Mint.TransportError{reason: :econnrefused}} ->
        {:error, :sandbox_unavailable}

      {:error, reason} ->
        {:error, "Zypi request failed: #{truncate(inspect(reason), 200)}"}
    end
  end

  defp get(path) do
    url = sandbox_url() <> path

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, decode_body(body)}

      {:error, %Mint.TransportError{reason: :econnrefused}} ->
        {:error, :sandbox_unavailable}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp delete(path) do
    url = sandbox_url() <> path
    _ = Req.delete(url, receive_timeout: 5_000)
    :ok
  end

  defp health_check(url) do
    case Req.get(url <> "/health", receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> :ok
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp decode_body(body), do: body

  defp sandbox_url do
    Mosaic.Config.get(:fabric_sandbox_url) ||
      Application.get_env(:mosaic, :fabric, [])[:sandbox_url]
  end

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str
end

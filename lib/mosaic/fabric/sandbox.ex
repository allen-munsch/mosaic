defmodule Mosaic.Fabric.Sandbox do
  @moduledoc """
  HTTP client for Zypi's agent sandbox executor API.

  Zypi provides OCI-compliant microVM execution via Firecracker (or QEMU/Hyper-V/Virt.framework).
  This module wraps Zypi's REST API so MosaicDB's MCP tools can provision sandboxes,
  execute commands, manage sessions, and store results in the fabric memory.

  Zypi endpoints used:
    POST /exec                    — One-shot command execution
    POST /containers              — Create a long-lived sandbox
    POST /containers/:id/start    — Start the microVM
    POST /containers/:id/stop     — Stop the microVM
    DELETE /containers/:id        — Destroy the microVM
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
    env = Keyword.get(opts, :env, %{})
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 30)
    files = Keyword.get(opts, :files, %{})

    body = %{
      cmd: cmd,
      image: image,
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
           timed_out: result["timed_out"] || false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Create a long-lived sandbox session. Returns session info including container_id and IP."
  def session_create(image \\ "ubuntu:24.04", opts \\ []) do
    container_id = "fabric_" <> random_id()
    env = Keyword.get(opts, :env, %{})
    workdir = Keyword.get(opts, :workdir, "/")

    body = %{
      id: container_id,
      image: image,
      cmd: ["sleep", "infinity"],
      resources: %{
        cpu: Keyword.get(opts, :vcpus, 1),
        memory_mb: Keyword.get(opts, :memory_mb, 256)
      }
    } |> add_env_config(env, workdir)

    with {:ok, created} <- post("/containers", body),
         {:ok, _started} <- post("/containers/#{container_id}/start", %{}) do
      {:ok,
       %{
         session_id: container_id,
         container_id: container_id,
         image: image,
         status: "running",
         created_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      {:error, reason} ->
        # Best-effort cleanup on failure
        delete("/containers/#{container_id}")
        {:error, reason}
    end
  end

  @doc "Execute a command in an existing sandbox session."
  def session_exec(session_id, cmd, opts \\ []) do
    env = Keyword.get(opts, :env, %{})
    workdir = Keyword.get(opts, :workdir)
    timeout = Keyword.get(opts, :timeout, 30)

    body = %{
      cmd: cmd,
      env: env,
      workdir: workdir,
      timeout: timeout
    } |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    # Session exec uses the same /exec endpoint, referencing the session's container
    case post("/exec", Map.put(body, :image, "session:#{session_id}")) do
      {:ok, %{"exit_code" => code} = result} ->
        {:ok,
         %{
           exit_code: code,
           stdout: result["stdout"] || "",
           stderr: result["stderr"] || "",
           duration_ms: result["duration_ms"],
           timed_out: result["timed_out"] || false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Close and destroy a sandbox session."
  def session_close(session_id) do
    _ = post("/containers/#{session_id}/stop", %{})
    delete("/containers/#{session_id}")
    :ok
  end

  @doc "Get VM pool statistics from Zypi."
  def pool_stats do
    case get("/pool/stats") do
      {:ok, stats} -> {:ok, stats}
      {:error, reason} -> {:error, reason}
    end
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

  defp random_id, do: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

  defp add_env_config(body, env, workdir) when map_size(env) > 0 do
    env_list = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
    put_in(body, [:env], env_list)
  end

  defp add_env_config(body, _env, workdir) when not is_nil(workdir) do
    Map.put(body, :workdir, workdir)
  end

  defp add_env_config(body, _env, _workdir), do: body

  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max) <> "..."
  end

  defp truncate(str, _max), do: str
end

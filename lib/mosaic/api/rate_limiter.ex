defmodule Mosaic.API.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for the MosaicDB HTTP API.

  Uses ETS for high-performance, low-latency rate limiting with:
  - Per-tenant buckets (if auth is enabled)
  - Per-IP buckets (fallback for unauthenticated requests)
  - Configurable rate: buckets refill at `rate_per_minute` tokens/min
  - Configurable burst: max `burst_size` tokens

  ## Usage (in a Plug pipeline)

      plug Mosaic.API.RateLimiter, rate: 1000, burst: 100

  Returns 429 Too Many Requests with Retry-After header when limit exceeded.
  """

  import Plug.Conn

  @table_name :mosaic_rate_limiter_buckets
  @cleanup_interval_ms 60_000

  @doc false
  def init(opts) do
    rate = Keyword.get(opts, :rate, Mosaic.Config.get(:api_rate_limit_per_minute, 1000))
    burst = Keyword.get(opts, :burst, rate * 2)
    %{rate: rate, burst: burst}
  end

  @doc false
  def call(conn, %{rate: rate, burst: burst}) do
    ensure_table()

    key = bucket_key(conn)

    if allow_request?(key, rate, burst) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("retry-after", "60")
      |> send_resp(429, Jason.encode!(%{
        error: "rate_limit_exceeded",
        detail: "Too many requests. Retry after 60 seconds.",
        limit: rate,
        window: "60s"
      }))
      |> halt()
    end
  end

  @doc """
  Check if a specific key (tenant, IP, or custom) is allowed to make a request.
  Returns `true` or `false`.
  """
  def allow_request?(key, rate_per_minute, burst_size \\ nil) when is_binary(key) do
    burst = burst_size || rate_per_minute * 2
    ensure_table()

    now = System.monotonic_time(:millisecond)
    refill_interval = 60_000  # 1 minute

    case :ets.lookup(@table_name, key) do
      [{^key, tokens, last_refill}] ->
        elapsed = now - last_refill
        new_tokens = min(burst, tokens + (elapsed / refill_interval) * rate_per_minute)

        if new_tokens >= 1.0 do
          :ets.insert(@table_name, {key, new_tokens - 1.0, now})
          true
        else
          false
        end

      [] ->
        # First request — initialize bucket
        :ets.insert(@table_name, {key, burst - 1.0, now})
        true
    end
  end

  @doc """
  Get current token count for a bucket (for monitoring).
  """
  def bucket_status(key) when is_binary(key) do
    ensure_table()
    case :ets.lookup(@table_name, key) do
      [{^key, tokens, last_refill}] ->
        now = System.monotonic_time(:millisecond)
        %{
          key: key,
          tokens: Float.round(tokens, 1),
          last_refill_ms_ago: now - last_refill
        }
      [] ->
        %{key: key, tokens: nil, status: :no_bucket}
    end
  end

  @doc "List all active rate limit buckets (for admin/monitoring)."
  def active_buckets(limit \\ 100) do
    ensure_table()
    :ets.tab2list(@table_name)
    |> Enum.take(limit)
    |> Enum.map(fn {key, tokens, _} -> %{key: key, tokens: Float.round(tokens, 1)} end)
  end

  @doc "Reset all rate limit buckets."
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc "Reset bucket for a specific key."
  def reset_key(key) when is_binary(key) do
    ensure_table()
    :ets.delete(@table_name, key)
    :ok
  end

  # ── Private ────────────────────────────────────────────────

  defp ensure_table do
    # Idempotent table creation — safe for concurrent calls.
    # Using :ets.info (not Process.whereis) to check the actual ETS table,
    # not a process that may have died without cleaning up the table.
    case :ets.info(@table_name) do
      :undefined ->
        try do
          :ets.new(@table_name, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok  # already created by concurrent caller
        end
        start_cleanup_timer()

      _ ->
        # Table already exists — ensure cleanup timer is running
        unless Process.whereis(:rate_limiter_cleanup) do
          start_cleanup_timer()
        end
    end
    :ok
  end

  defp start_cleanup_timer do
    spawn(fn ->
      try do
        Process.register(self(), :rate_limiter_cleanup)
        cleanup_loop()
      rescue
        ArgumentError -> :already_registered
      end
    end)
  end

  defp cleanup_loop do
    Process.sleep(@cleanup_interval_ms)
    now = System.monotonic_time(:millisecond)
    stale_threshold = now - 120_000  # 2 minutes

    # Remove stale buckets
    :ets.select_delete(@table_name, [{{:"$1", :_, :"$2"}, [{:<, :"$2", stale_threshold}], [true]}])

    cleanup_loop()
  end

  defp bucket_key(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    # Try tenant ID first (from auth plug)
    case conn.assigns[:auth_claims] do
      %{tenant_id: tid} when is_binary(tid) ->
        "tenant:#{tid}:#{conn.method}"

      _ ->
        # Fall back to IP-based rate limiting
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        "ip:#{ip}:#{conn.method}"
    end
  end
end

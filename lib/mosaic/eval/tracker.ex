defmodule Mosaic.Eval.Tracker do
  require Logger
  @moduledoc """
  Continuous evaluation harness for MosaicDB retrieval quality.

  Tracks retrieval metrics (precision, recall, MRR, NDCG, latency)
  and can alert when quality degrades below thresholds.

  ## Usage

      # Track a retrieval event
      Mosaic.Eval.Tracker.track(:retrieval,
        query: "auth flow",
        retrieved: [%{id: "auth.ex:45", similarity: 0.92}, ...],
        expected: ["auth.ex:45", "auth.ex:67"],
        relevance_scores: [0.92, 0.78, 0.45],
        latency_ms: 23
      )

      # Get a report
      Mosaic.Eval.Tracker.report(:retrieval, last: :week)
      # → %{precision_at_5: 0.87, recall_at_10: 0.94, mrr: 0.91, ...}

      # Set up monitoring with alerting
      Mosaic.Eval.Tracker.monitor(:retrieval,
        alert_if: %{precision_at_5: 0.7, mrr: 0.6})
  """

  @doc """
  Record an evaluation event for later analysis.

  Required:
    - `:query` — the search query string
    - `:retrieved` — list of retrieved result maps (at least `[%{id: ...}]`)

  Optional:
    - `:expected` — list of expected/relevant document IDs
    - `:relevance_scores` — per-result relevance (0.0-1.0)
    - `:latency_ms` — query latency in milliseconds
    - `:session_id` — agent session for grouping
    - `:metadata` — arbitrary map
  """
  def track(metric_type, attrs) when is_atom(metric_type) do
    query = Keyword.fetch!(attrs, :query)
    retrieved = Keyword.get(attrs, :retrieved, [])
    expected = Keyword.get(attrs, :expected, [])
    relevance = Keyword.get(attrs, :relevance_scores, [])
    latency_ms = Keyword.get(attrs, :latency_ms)

    event = %{
      metric_type: metric_type,
      query: query,
      retrieved_count: length(retrieved),
      expected_count: length(expected),
      relevance_scores: relevance,
      latent_ms: latency_ms,
      session_id: Keyword.get(attrs, :session_id),
      metadata: Keyword.get(attrs, :metadata, %{}),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with {:ok, conn} <- get_eval_conn(metric_type) do
      ret_ids = Enum.map(retrieved, &Map.get(&1, :id))

      Mosaic.DB.execute(conn, """
        INSERT INTO eval_events (event_type, query, retrieved_ids, expected_ids,
          relevance_scores, latency_ms, session_id, metadata)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, [
        Atom.to_string(metric_type), query,
        Jason.encode!(ret_ids), Jason.encode!(expected),
        Jason.encode!(relevance), latency_ms,
        event.session_id, Jason.encode!(event.metadata)
      ])

      release_conn(conn)
      :ok
    end
  end

  @doc """
  Generate a metrics report for the given evaluation type.

  Options:
    - `:last` — time window (`:hour`, `:day`, `:week`, `:month`)
    - `:since` — ISO8601 timestamp
    - `:k_values` — list of K values for precision/recall (default: [5, 10, 20])
  """
  def report(metric_type, opts \\ []) when is_atom(metric_type) do
    window = Keyword.get(opts, :last, :day)
    k_values = Keyword.get(opts, :k_values, [5, 10, 20])

    with {:ok, conn} <- get_eval_conn(metric_type) do
      cutoff = window_to_timestamp(window)

      {:ok, rows} = Mosaic.DB.query(conn, """
        SELECT retrieved_ids, expected_ids, relevance_scores, latency_ms
        FROM eval_events
        WHERE event_type = ? AND created_at > ?
        ORDER BY created_at DESC
        LIMIT 10000
      """, [Atom.to_string(metric_type), cutoff])

      release_conn(conn)

      events = Enum.map(rows, fn [ret_ids, exp_ids, rel_scores, latency] ->
        %{
          retrieved: safe_decode_list(ret_ids),
          expected: safe_decode_list(exp_ids),
          relevance: safe_decode_float_list(rel_scores),
          latency_ms: latency
        }
      end)

      metrics = compute_metrics(events, k_values)

      {:ok,
        Map.merge(metrics, %{
          total_events: length(events),
          window: window,
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      }
    end
  end

  @doc """
  Set up monitoring with alert thresholds. If metrics drop below thresholds,
  a warning is logged (can be extended to webhooks/PagerDuty).

  Example thresholds:
      %{precision_at_5: 0.7, mrr: 0.6, recall_at_10: 0.8}
  """
  def monitor(metric_type, opts) when is_atom(metric_type) do
    thresholds = Keyword.fetch!(opts, :alert_if)

    case report(metric_type, last: :hour) do
      {:ok, metrics} ->
        violations = Enum.reduce(thresholds, [], fn {metric, threshold}, acc ->
          current = Map.get(metrics, metric, 1.0)
          if current < threshold do
            Logger.warning("Eval alert: #{metric_type}.#{metric} = #{current} (threshold: #{threshold})")
            [{metric, current, threshold} | acc]
          else
            acc
          end
        end)

        if violations == [] do
          {:ok, :healthy, metrics}
        else
          {:ok, :degraded, %{metrics: metrics, violations: violations}}
        end

      error -> error
    end
  end

  @doc "Get raw evaluation events for analysis."
  def events(metric_type, opts \\ []) when is_atom(metric_type) do
    limit = Keyword.get(opts, :limit, 100)
    window = Keyword.get(opts, :last, :day)

    with {:ok, conn} <- get_eval_conn(metric_type) do
      cutoff = window_to_timestamp(window)

      {:ok, rows} = Mosaic.DB.query(conn, """
        SELECT query, retrieved_ids, expected_ids, relevance_scores, latency_ms, created_at
        FROM eval_events
        WHERE event_type = ? AND created_at > ?
        ORDER BY created_at DESC
        LIMIT ?
      """, [Atom.to_string(metric_type), cutoff, limit])

      release_conn(conn)

      events = Enum.map(rows, fn [query, ret_ids, exp_ids, rel_scores, latency, ts] ->
        %{
          query: query,
          retrieved: safe_decode_list(ret_ids),
          expected: safe_decode_list(exp_ids),
          relevance: safe_decode_float_list(rel_scores),
          latency_ms: latency,
          timestamp: ts
        }
      end)

      {:ok, events}
    end
  end

  # ── Metrics Computation ────────────────────────────────────

  defp compute_metrics(events, k_values) do
    if events == [] do
      base = %{total_events: 0}
      k_metrics = Enum.flat_map(k_values, fn k ->
        [{"precision_at_#{k}", nil}, {"recall_at_#{k}", nil}]
      end) |> Map.new()
      Map.merge(base, %{
        mrr: nil,
        ndcg_at_10: nil,
        avg_latency_ms: nil,
        p50_latency_ms: nil,
        p95_latency_ms: nil,
        p99_latency_ms: nil
      }) |> Map.merge(k_metrics)
    else
      # Compute per-event metrics
      per_event = Enum.map(events, fn event ->
        k_metrics = Enum.flat_map(k_values, fn k ->
          precision = precision_at_k(event.retrieved, event.expected, k)
          recall = recall_at_k(event.retrieved, event.expected, k)
          [
            {String.to_atom("precision_at_#{k}"), precision},
            {String.to_atom("recall_at_#{k}"), recall}
          ]
        end)

        mrr = reciprocal_rank(event.retrieved, event.expected)
        ndcg = ndcg_at_k(event.relevance, 10)

        %{mrr: mrr, ndcg_at_10: ndcg, latency: event.latency_ms}
        |> Map.merge(k_metrics |> Map.new())
      end)

      # Aggregate
      avg = fn list, field ->
        vals = Enum.map(list, &Map.get(&1, field)) |> Enum.reject(&is_nil/1)
        if vals == [], do: nil, else: Float.round(Enum.sum(vals) / length(vals), 4)
      end

      latencies = Enum.map(per_event, & &1.latency) |> Enum.reject(&is_nil/1) |> Enum.sort()

      k_metrics = Enum.flat_map(k_values, fn k ->
        [
          {String.to_atom("precision_at_#{k}"), avg.(per_event, String.to_atom("precision_at_#{k}"))},
          {String.to_atom("recall_at_#{k}"), avg.(per_event, String.to_atom("recall_at_#{k}"))}
        ]
      end)

      %{
        total_events: length(events),
        mrr: avg.(per_event, :mrr),
        ndcg_at_10: avg.(per_event, :ndcg_at_10),
        avg_latency_ms: avg.(per_event, :latency),
        p50_latency_ms: percentile(latencies, 0.50),
        p95_latency_ms: percentile(latencies, 0.95),
        p99_latency_ms: percentile(latencies, 0.99)
      }
      |> Map.merge(k_metrics |> Map.new())
    end
  end

  defp precision_at_k(retrieved, expected, k) do
    retrieved_k = Enum.take(retrieved, k)
    expected_set = MapSet.new(expected || [])

    if retrieved_k == [] do
      1.0  # empty result for empty expected? Return 1.0 to avoid NaN
    else
      hits = Enum.count(retrieved_k, &MapSet.member?(expected_set, &1))
      Float.round(hits / min(k, length(retrieved_k)), 4)
    end
  end

  defp recall_at_k(retrieved, expected, k) do
    expected = expected || []
    if expected == [] do
      1.0
    else
      retrieved_k = Enum.take(retrieved, k)
      expected_set = MapSet.new(expected)
      hits = Enum.count(retrieved_k, &MapSet.member?(expected_set, &1))
      Float.round(hits / length(expected), 4)
    end
  end

  defp reciprocal_rank(retrieved, expected) do
    expected = expected || []
    if expected == [] do
      1.0
    else
      expected_set = MapSet.new(expected)
      rank = Enum.find_index(retrieved, &MapSet.member?(expected_set, &1))
      case rank do
        nil -> 0.0
        n -> Float.round(1.0 / (n + 1), 4)
      end
    end
  end

  defp ndcg_at_k(relevance_scores, k) do
    scores = relevance_scores || []
    if scores == [] do
      1.0
    else
      dcg = scores
        |> Enum.take(k)
        |> Enum.with_index(1)
        |> Enum.reduce(0.0, fn {rel, i}, acc ->
          acc + rel / :math.log2(i + 1)
        end)

      idcg = scores
        |> Enum.sort(:desc)
        |> Enum.take(k)
        |> Enum.with_index(1)
        |> Enum.reduce(0.0, fn {rel, i}, acc ->
          acc + rel / :math.log2(i + 1)
        end)

      if idcg == 0.0, do: 0.0, else: Float.round(dcg / idcg, 4)
    end
  end

  defp percentile([], _), do: nil
  defp percentile(sorted, p) do
    idx = round(p * (length(sorted) - 1))
    Enum.at(sorted, idx)
  end

  # ── Storage ────────────────────────────────────────────────

  defp get_eval_conn(metric_type) do
    path = eval_db_path(metric_type)
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    ensure_eval_schema(path)
    Mosaic.ConnectionPool.checkout(path)
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(
      Mosaic.Config.get(:eval_db_base_path, Path.join(Mosaic.Config.get(:storage_path), "eval")),
      conn
    )
  end

  defp eval_db_path(metric_type) do
    base = Mosaic.Config.get(:eval_db_base_path, Path.join(Mosaic.Config.get(:storage_path), "eval"))
    Path.join(base, "eval_#{metric_type}.db")
  end

  defp ensure_eval_schema(path) do
    key = :"eval_schema_#{Path.basename(path)}"
    unless Process.get(key) do
      Process.put(key, true)
      Mosaic.ConnectionPool.scoped_checkout(path, fn conn ->
        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS eval_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            query TEXT NOT NULL,
            retrieved_ids TEXT,
            expected_ids TEXT,
            relevance_scores TEXT,
            latency_ms INTEGER,
            session_id TEXT,
            metadata TEXT,
            created_at TEXT DEFAULT (datetime('now'))
          );
        """)

        Mosaic.DB.execute(conn, "CREATE INDEX IF NOT EXISTS idx_eval_type_time ON eval_events(event_type, created_at);")
        :ok
      end)
    end
  end

  defp window_to_timestamp(:hour), do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
  defp window_to_timestamp(:day), do: DateTime.utc_now() |> DateTime.add(-86400, :second) |> DateTime.to_iso8601()
  defp window_to_timestamp(:week), do: DateTime.utc_now() |> DateTime.add(-604800, :second) |> DateTime.to_iso8601()
  defp window_to_timestamp(:month), do: DateTime.utc_now() |> DateTime.add(-2592000, :second) |> DateTime.to_iso8601()

  defp safe_decode_list(nil), do: []
  defp safe_decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp safe_decode_float_list(nil), do: []
  defp safe_decode_float_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_float/1)
      _ -> []
    end
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_number(v), do: v * 1.0
  defp to_float(_), do: 0.0
end

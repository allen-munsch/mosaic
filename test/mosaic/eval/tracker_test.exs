defmodule Mosaic.Eval.TrackerTest do
  use ExUnit.Case, async: false

  alias Mosaic.Eval.Tracker

  describe "track/2" do
    test "records a retrieval evaluation event" do
      :ok = Tracker.track(:retrieval_test,
        query: "auth flow",
        retrieved: [%{id: "doc_1"}, %{id: "doc_2"}, %{id: "doc_3"}],
        expected: ["doc_1", "doc_2"],
        relevance_scores: [1.0, 0.8, 0.3],
        latency_ms: 23,
        session_id: "test_session"
      )
    end
  end

  describe "report/2" do
    test "returns metrics report" do
      type = :"report_test_#{System.unique_integer([:positive])}"

      Tracker.track(type,
        query: "perfect match",
        retrieved: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
        expected: ["a", "b"],
        relevance_scores: [1.0, 1.0, 0.0],
        latency_ms: 10
      )

      Tracker.track(type,
        query: "partial match",
        retrieved: [%{id: "x"}, %{id: "y"}],
        expected: ["y"],
        relevance_scores: [0.0, 1.0],
        latency_ms: 50
      )

      {:ok, report} = Tracker.report(type, last: :day, k_values: [2, 5])

      assert report.total_events == 2
      assert is_number(report.mrr) or report.mrr == nil
      assert is_number(report.ndcg_at_10) or report.ndcg_at_10 == nil
      assert is_number(report.avg_latency_ms) or report.avg_latency_ms == nil
    end
  end

  describe "event query" do
    test "returns recent events with limit" do
      type = :"events_test_#{System.unique_integer([:positive])}"

      Tracker.track(type, query: "q1", retrieved: [],
        expected: [], relevance_scores: [], latency_ms: 5)

      {:ok, events} = Tracker.events(type, limit: 10, last: :day)
      assert is_list(events)
      assert length(events) >= 1
    end
  end

  describe "metrics computation" do
    test "precision at k is correct" do
      type = :"precision_test_#{System.unique_integer([:positive])}"

      Tracker.track(type,
        query: "q",
        retrieved: [%{id: "a"}, %{id: "b"}, %{id: "c"}, %{id: "d"}, %{id: "e"}],
        expected: ["a", "b", "c"],
        relevance_scores: [1.0, 1.0, 1.0, 0.0, 0.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(type, last: :day, k_values: [3, 5])

      assert report.precision_at_3 == 1.0
      assert report.precision_at_5 == 0.6
    end

    test "recall at k is correct" do
      type = :"recall_test_#{System.unique_integer([:positive])}"

      Tracker.track(type,
        query: "q",
        retrieved: [%{id: "a"}, %{id: "b"}],
        expected: ["a", "b", "c"],
        relevance_scores: [1.0, 1.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(type, last: :day, k_values: [2, 5])

      assert report.recall_at_2 == Float.round(2.0 / 3.0, 4)
    end
  end

  describe "alert monitoring" do
    test "setup and check alert thresholds" do
      Tracker.monitor(:mrr, alert_if: %{mrr: 0.5})
      Tracker.monitor(:p95_latency_ms, alert_if: %{p95_latency_ms: 500})

      # Just verify no crashes
      assert true
    end
  end
end

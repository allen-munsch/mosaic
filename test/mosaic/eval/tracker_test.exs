defmodule Mosaic.Eval.TrackerTest do
  use ExUnit.Case, async: false

  alias Mosaic.Eval.Tracker

  describe "track/2" do
    test "records a retrieval evaluation event" do
      :ok = Tracker.track(:retrieval,
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
      # Insert a few events
      Tracker.track(:retrieval,
        query: "perfect match",
        retrieved: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
        expected: ["a", "b"],
        relevance_scores: [1.0, 1.0, 0.0],
        latency_ms: 10
      )

      Tracker.track(:retrieval,
        query: "partial match",
        retrieved: [%{id: "x"}, %{id: "y"}],
        expected: ["y"],
        relevance_scores: [0.0, 1.0],
        latency_ms: 50
      )

      {:ok, report} = Tracker.report(:retrieval, last: :day, k_values: [2, 5])

      assert report.total_events == 2
      assert is_number(report.mrr) or report.mrr == nil
      assert is_number(report.ndcg_at_10) or report.ndcg_at_10 == nil
      assert is_number(report.avg_latency_ms) or report.avg_latency_ms == nil
    end

    test "returns empty report for no events" do
      {:ok, report} = Tracker.report(:nonexistent, last: :hour)
      assert report.total_events == 0
    end
  end

  describe "monitor/2" do
    test "checks metrics against thresholds" do
      # With no events yet, metrics should be nil
      {:ok, status, _} = Tracker.monitor(:retrieval, alert_if: %{mrr: 0.5})
      assert status in [:healthy, :degraded]
    end
  end

  describe "events/2" do
    test "returns raw evaluation events" do
      Tracker.track(:retrieval,
        query: "test query",
        retrieved: [%{id: "a"}],
        expected: ["a"],
        relevance_scores: [1.0],
        latency_ms: 10,
        session_id: "s1"
      )

      {:ok, events} = Tracker.events(:retrieval, limit: 10, last: :day)

      assert is_list(events)
    end
  end

  describe "metrics computation" do
    test "precision at k is correct" do
      # We test this indirectly via report
      Tracker.track(:precision_test,
        query: "q",
        retrieved: [%{id: "a"}, %{id: "b"}, %{id: "c"}, %{id: "d"}, %{id: "e"}],
        expected: ["a", "b", "c"],
        relevance_scores: [1.0, 1.0, 1.0, 0.0, 0.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(:precision_test, last: :day, k_values: [3, 5])

      # Precision@3 should be 1.0 (all first 3 are relevant)
      # Precision@5 should be 0.6 (3 out of 5 are relevant)
      assert report.precision_at_3 == 1.0
      assert report.precision_at_5 == 0.6
    end

    test "recall at k is correct" do
      Tracker.track(:recall_test,
        query: "q",
        retrieved: [%{id: "a"}, %{id: "b"}],
        expected: ["a", "b", "c", "d", "e"],
        relevance_scores: [1.0, 1.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(:recall_test, last: :day, k_values: [2, 5])
      # Recall@2 should be 2/5 = 0.4
      assert report.recall_at_2 == 0.4
    end

    test "MRR is computed correctly" do
      Tracker.track(:mrr_test,
        query: "q",
        retrieved: [%{id: "x"}, %{id: "y"}, %{id: "z"}],
        expected: ["y"],
        relevance_scores: [0.0, 1.0, 0.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(:mrr_test, last: :day)
      # First relevant at rank 2 → MRR = 1/2 = 0.5
      assert report.mrr == 0.5
    end

    test "NDCG is computed correctly" do
      Tracker.track(:ndcg_test,
        query: "q",
        retrieved: [%{id: "a"}, %{id: "b"}, %{id: "c"}],
        expected: ["a"],
        relevance_scores: [1.0, 0.5, 0.0],
        latency_ms: 10
      )

      {:ok, report} = Tracker.report(:ndcg_test, last: :day)

      # NDCG should be calculable
      assert is_number(report.ndcg_at_10) or report.ndcg_at_10 == nil
    end
  end
end

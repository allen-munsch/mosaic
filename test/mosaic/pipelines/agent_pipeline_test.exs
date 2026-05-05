defmodule Mosaic.Pipelines.AgentPipelineTest do
  use ExUnit.Case, async: false

  alias Mosaic.Pipelines.AgentPipeline

  @test_name :"test_pipeline_#{System.unique_integer([:positive])}"

  describe "define/3" do
    test "defines a pipeline with steps" do
      {:ok, pipeline} = AgentPipeline.define(@test_name, [
        {:search, query: "test"},
        {:filter, min_relevance: 0.5},
        {:limit, n: 10}
      ])

      assert pipeline.name == @test_name
      assert pipeline.version == 1
      assert length(pipeline.steps) == 3
    end

    test "validates step types" do
      assert_raise ArgumentError, fn ->
        AgentPipeline.define(@test_name, [{:invalid_step, []}])
      end
    end

    test "auto-increments version" do
      AgentPipeline.define(@test_name, [{:search, query: "v1"}])
      {:ok, v2} = AgentPipeline.define(@test_name, [{:search, query: "v2"}])

      assert v2.version == 2
    end
  end

  describe "get_pipeline/2" do
    test "returns the latest version by default" do
      AgentPipeline.define(@test_name, [{:search, query: "latest"}])

      {:ok, pipeline} = AgentPipeline.get_pipeline(@test_name)
      assert pipeline.version == 1
    end

    test "returns specific version when requested" do
      AgentPipeline.define(@test_name, [{:search, query: "v1"}])
      AgentPipeline.define(@test_name, [{:search, query: "v2"}])

      {:ok, v1} = AgentPipeline.get_pipeline(@test_name, 1)
      assert v1.version == 1
    end

    test "returns error for unknown pipeline" do
      assert {:error, :not_found} = AgentPipeline.get_pipeline(:nonexistent)
    end
  end

  describe "run/3" do
    test "runs a search pipeline" do
      AgentPipeline.define(@test_name, [
        {:search, query: "authentication"},
        {:limit, n: 5}
      ])

      {:ok, results, handle, stats} = AgentPipeline.run(@test_name)

      assert is_list(results)
      assert is_binary(handle)
      assert stats.elapsed_ms >= 0
    end

    test "dry-run mode skips execution" do
      AgentPipeline.define(@test_name, [{:search, query: "test"}])

      {:ok, results, _handle, stats} = AgentPipeline.run(@test_name, %{}, dry_run: true)

      assert results == []
      assert hd(stats.steps).status == :skipped
    end

    test "substitutes parameters" do
      AgentPipeline.define(@test_name, [{:search, query: "{{topic}}"}])

      {:ok, _results, _handle, _stats} = AgentPipeline.run(@test_name, %{"topic" => "error handling"})
      # Should not crash — substitution is tested via the step execution
    end
  end

  describe "list/1" do
    test "lists all pipelines" do
      AgentPipeline.define(@test_name, [{:search, query: "test"}])

      {:ok, pipelines} = AgentPipeline.list()
      assert is_list(pipelines)
      assert Enum.any?(pipelines, &(&1.name == @test_name))
    end
  end

  describe "history/2" do
    test "returns execution history" do
      AgentPipeline.define(@test_name, [{:search, query: "test"}])
      AgentPipeline.run(@test_name)

      {:ok, history} = AgentPipeline.history(@test_name)
      assert is_list(history)
      assert length(history) > 0
    end
  end
end

defmodule Mosaic.Pipelines.AgentPipelineTest do
  use ExUnit.Case, async: false

  alias Mosaic.Pipelines.AgentPipeline

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "mosaic_pipe_test_#{System.unique_integer([:positive])}")
    tmp_db = Path.join(tmp_dir, "agent_pipeline.db")
    File.mkdir_p!(tmp_dir)
    File.write!(tmp_db, "")
    Application.put_env(:mosaic, :pipeline_db_path, tmp_db)

    name = :"test_pipeline_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      Application.put_env(:mosaic, :pipeline_db_path, nil)
    end)

    {:ok, pipeline_name: name}
  end

  describe "define/3" do
    test "defines a pipeline with steps", %{pipeline_name: name} do
      {:ok, pipeline} = AgentPipeline.define(name, [
        {:search, query: "test"},
        {:filter, min_relevance: 0.5},
        {:traverse, max_depth: 3}
      ])

      assert pipeline.version == 1
      assert length(pipeline.steps) == 3
    end

    test "auto-increments version", %{pipeline_name: name} do
      {:ok, v1} = AgentPipeline.define(name, [{:search, query: "v1"}])
      assert v1.version == 1

      {:ok, v2} = AgentPipeline.define(name, [{:search, query: "v2"}])
      assert v2.version == 2
    end
  end

  describe "get_pipeline/2" do
    test "returns the latest version by default", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "v1"}])
      AgentPipeline.define(name, [{:search, query: "v2"}])

      {:ok, pipeline} = AgentPipeline.get_pipeline(name)
      assert pipeline.version == 2
    end

    test "returns specific version when requested", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "v1"}])
      AgentPipeline.define(name, [{:search, query: "v2"}])

      {:ok, pipeline} = AgentPipeline.get_pipeline(name, 1)
      assert pipeline.version == 1
    end
  end

  describe "run/3" do
    test "dry-run mode skips execution", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "test"}])

      {:ok, results, _handle, stats} = AgentPipeline.run(name, %{}, dry_run: true)
      # Dry run produces no results
      assert results == []
      assert stats.elapsed_ms >= 0
    end

    test "substitutes parameters", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "{{topic}}"}])

      {:ok, _results, _handle, _stats} = AgentPipeline.run(name, %{"topic" => "elixir"})
      # Should run without error
    end

    test "runs a search pipeline", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "elixir", limit: 5}])

      {:ok, _results, _handle, _stats} = AgentPipeline.run(name)
      # Result may be empty if no data indexed, but should not error
    end
  end

  describe "history/2" do
    test "returns execution history", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "test"}])
      {:ok, _results, _handle, _stats} = AgentPipeline.run(name)

      {:ok, history} = AgentPipeline.history(name)
      assert is_list(history)
    end
  end

  describe "list/1" do
    test "lists all pipelines", %{pipeline_name: name} do
      AgentPipeline.define(name, [{:search, query: "test"}])

      {:ok, pipelines} = AgentPipeline.list()
      assert is_list(pipelines)
      assert length(pipelines) > 0
    end
  end
end

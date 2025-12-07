defmodule Mosaic.Index.StrategyIntegrationTest do
  use ExUnit.Case, async: true
  doctest Mosaic.QueryEngine

  alias Mosaic.Config
  alias Mosaic.EmbeddingService
  alias Mosaic.QueryEngine
  alias Mosaic.Index.Strategy.Centroid
  alias Mosaic.Index.Strategy.Quantized

  setup do
    # Clear any previous test state
    :ok = Mosaic.StorageManager.reset_storage()
    :ok = Mosaic.ShardRouter.reset_state()

    # Mock EmbeddingService for predictable embeddings
    Mox.stub(Mosaic.EmbeddingServiceMock, :encode, fn text ->
      case text do
        "hello world" -> [0.1, 0.2, 0.3, 0.4]
        "elixir rocks" -> [0.4, 0.3, 0.2, 0.1]
        "acme ai" -> [0.2, 0.3, 0.1, 0.4]
        _ -> List.duplicate(0.0, 4)
      end
    end)

    Mox.stub(Mosaic.EmbeddingServiceMock, :encode_batch, fn texts ->
      Enum.map(texts, fn text ->
        case text do
          "hello world" -> [0.1, 0.2, 0.3, 0.4]
          "elixir rocks" -> [0.4, 0.3, 0.2, 0.1]
          "acme ai" -> [0.2, 0.3, 0.1, 0.4]
          _ -> List.duplicate(0.0, 4)
        end
      end)
    end)

    # Start the application with a specific strategy (will be overridden in tests)
    {:ok, _pid} = Application.ensure_all_started(:mosaic)
    :ok
  end

  @tag :centroid
  test "Centroid strategy: indexes and queries documents correctly" do
    # Ensure centroid strategy is active for this test
    Application.put_env(:mosaic, :index_strategy, "centroid")
    Application.put_env(:mosaic, :embedding_dim, 4) # Match mocked embeddings

    # Re-initialize QueryEngine with the correct strategy
    {:ok, pid} = QueryEngine.start_link(
      cache: Mosaic.Cache.ETS,
      ranker: Mosaic.Ranking.Ranker.new(),
      index_strategy: "centroid"
    )

    # Index some documents
    QueryEngine.handle_call({:execute_query, "hello world", [action: :index, id: "doc1", text: "hello world"]}, self(), QueryEngine.state())
    QueryEngine.handle_call({:execute_query, "elixir rocks", [action: :index, id: "doc2", text: "elixir rocks"]}, self(), QueryEngine.state())

    # Query for "hello world"
    {:reply, {:ok, results}, _} = QueryEngine.handle_call({:execute_query, "hello world", []}, self(), QueryEngine.state())

    assert length(results) == 1
    assert List.first(results).doc_id == "doc1"
    assert List.first(results).text =~ "hello world"
  end

  @tag :quantized
  test "Quantized strategy: indexes and queries documents correctly" do
    # Ensure quantized strategy is active for this test
    Application.put_env(:mosaic, :index_strategy, "quantized")
    Application.put_env(:mosaic, :embedding_dim, 4) # Match mocked embeddings
    Application.put_env(:mosaic, :quantized_bins, 4)
    Application.put_env(:mosaic, :quantized_dims_per_level, 2)
    Application.put_env(:mosaic, :quantized_cell_capacity, 100)
    Application.put_env(:mosaic, :quantized_search_radius, 1)

    # Re-initialize QueryEngine with the correct strategy
    {:ok, pid} = QueryEngine.start_link(
      cache: Mosaic.Cache.ETS,
      ranker: Mosaic.Ranking.Ranker.new(),
      index_strategy: "quantized"
    )

    # Index some documents
    QueryEngine.handle_call({:execute_query, "acme ai", [action: :index, id: "doc3", text: "acme ai"]}, self(), QueryEngine.state())
    QueryEngine.handle_call({:execute_query, "elixir rocks", [action: :index, id: "doc4", text: "elixir rocks"]}, self(), QueryEngine.state())

    # Query for "acme ai"
    {:reply, {:ok, results}, _} = QueryEngine.handle_call({:execute_query, "acme ai", []}, self(), QueryEngine.state())

    assert length(results) >= 1 # Quantized might return more or less based on binning
    assert Enum.any?(results, fn r -> r.id == "doc3" end)
  end
end

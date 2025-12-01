defmodule Mosaic.APITest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  
  setup context do
    Mosaic.TestHelpers.setup_integration_test(context)
    # Index a test document
    doc_id = "api_test_doc_1"
    text = "This document is for API testing. It contains a sentence about Elixir and another about Phoenix."
    {:ok, _} = Mosaic.Indexer.index_document(doc_id, text)
    Process.sleep(200) # Allow indexing to complete
    :ok
  end

  @opts Mosaic.API.init([])

  describe "GET /health" do
    test "returns 200 OK" do
      conn = conn(:get, "/health") |> Mosaic.API.call(@opts)
      assert conn.status == 200
      assert conn.resp_body == "ok"
    end
  end

  describe "POST /api/search" do
    test "with valid query returns results" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: "Elixir"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["results"])
    end

    test "with empty query returns error" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: ""}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status == 400
      assert conn.resp_body =~ "query cannot be empty"
    end

    test "with invalid JSON returns 400" do
      conn = conn(:post, "/api/search", "not json")
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status == 400
      assert conn.resp_body =~ "Invalid JSON"
    end
  end

  describe "POST /api/search/grounded" do
    test "with valid query returns grounded results (default level)" do
      conn = conn(:post, "/api/search/grounded", Jason.encode!(%{query: "Phoenix"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["level"] == "paragraph"
      assert is_list(body["results"])
      result = hd(body["results"])
      assert Map.has_key?(result, "grounding")
      grounding = result["grounding"]
      assert Map.get(grounding, "doc_id") == "api_test_doc_1"
      assert Map.get(grounding, "citation") != nil
    end

    test "with valid query and specified level returns grounded results" do
      conn = conn(:post, "/api/search/grounded", Jason.encode!(%{query: "Elixir", level: "sentence"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["level"] == "sentence"
      assert is_list(body["results"])
      result = hd(body["results"])
      assert Map.has_key?(result, "grounding")
    end
  end
end
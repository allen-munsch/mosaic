defmodule Mosaic.APITest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import Mosaic.TestHelpers

  setup context do
    {:ok, setup_context} = Mosaic.TestHelpers.setup_integration_test(context)
    on_exit(setup_context.on_exit)
    {result, conn} = index_and_connect("api_doc", "Document about Elixir and Phoenix for API testing.")
    on_exit(fn -> cleanup_conn(result.shard_path, conn) end)
    {:ok, Map.merge(setup_context, %{shard: result})}
  end

  @opts Mosaic.API.init([])

  describe "GET /health" do
    test "returns 200" do
      conn = conn(:get, "/health") |> Mosaic.API.call( @opts)
      assert conn.status == 200
    end
  end

  describe "POST /api/search" do
    test "returns results for valid query" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: "Elixir"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call( @opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["results"])
    end

    test "returns 400 for empty query" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: ""}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call( @opts)
      assert conn.status == 400
    end
  end

  describe "POST /api/search/grounded" do
    test "returns grounded results" do
      conn = conn(:post, "/api/search/grounded", Jason.encode!(%{query: "Phoenix", level: "paragraph"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call( @opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["level"] == "paragraph"
      result = hd(body["results"])
      assert Map.has_key?(result, "grounding")
    end
  end

  describe "DELETE /api/documents/:id" do
    test "deletes document" do
      {_result, _} = index_and_connect("delete_me", "Document to delete.")
      conn = conn(:delete, "/api/documents/delete_me") |> Mosaic.API.call( @opts)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "deleted"
    end
  end
end

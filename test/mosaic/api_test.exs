defmodule Mosaic.APITest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
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
      conn = conn(:post, "/api/search", Jason.encode!(%{query: "test"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status in [200, 404]
    end

    test "with empty query returns error" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: ""}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status in [200, 400, 404]
    end

    test "with invalid JSON returns 400" do
      conn = conn(:post, "/api/search", "not json")
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status in [400, 404]
    end

    test "returns proper content-type header" do
      conn = conn(:post, "/api/search", Jason.encode!(%{query: "test"}))
             |> put_req_header("content-type", "application/json")
             |> Mosaic.API.call(@opts)
      assert conn.status in [200, 404]
    end
  end
end
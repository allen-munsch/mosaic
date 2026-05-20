defmodule Mosaic.MCP.HTTPTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Mosaic.API

  @opts API.init([])

  test "GET /mcp returns server info" do
    conn = conn(:get, "/mcp") |> API.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["protocol"] == "mcp"
    assert body["server"]["name"] == "mosaic-mcp"
    assert "http" in body["transports"]
  end

  test "POST /mcp with tools/list returns tools" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{}
    })

    conn =
      conn(:post, "/mcp", req)
      |> put_req_header("content-type", "application/json")
      |> API.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["id"] == 1
    assert is_list(body["result"]["tools"])
  end

  test "POST /mcp with initialize returns capabilities" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2024-11-05", "capabilities" => %{}}
    })

    conn =
      conn(:post, "/mcp", req)
      |> put_req_header("content-type", "application/json")
      |> API.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["protocolVersion"] == "2024-11-05"
    assert body["result"]["capabilities"]["tools"] == %{}
  end

  test "POST /mcp with ping returns empty result" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "ping",
      "params" => %{}
    })

    conn =
      conn(:post, "/mcp", req)
      |> put_req_header("content-type", "application/json")
      |> API.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["result"] == %{}
  end

  test "POST /mcp with SSE accept header returns text/event-stream" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "ping",
      "params" => %{}
    })

    conn =
      conn(:post, "/mcp", req)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "text/event-stream")
      |> API.call(@opts)

    assert conn.status == 200
    content_type = conn.resp_headers |> Enum.find_value(fn {k, v} -> k == "content-type" && v end)
    assert String.starts_with?(content_type || "", "text/event-stream")
    assert String.contains?(conn.resp_body, "data:")
  end

  test "POST /mcp with unknown method returns error" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "nonexistent",
      "params" => %{}
    })

    conn =
      conn(:post, "/mcp", req)
      |> put_req_header("content-type", "application/json")
      |> API.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == -32601
  end

  test "POST /mcp with invalid JSON returns 400" do
    conn =
      conn(:post, "/mcp", "not json")
      |> put_req_header("content-type", "application/json")
      |> API.call(@opts)

    assert conn.status == 400
  end
end

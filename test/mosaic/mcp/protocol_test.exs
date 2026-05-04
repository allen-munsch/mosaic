defmodule Mosaic.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Mosaic.MCP.Protocol

  # Minimal tool handler for testing
  defmodule TestHandler do
    def list_tools do
      [
        %{
          name: "test_ping",
          description: "Test ping tool",
          inputSchema: %{type: "object", properties: %{}, required: []}
        }
      ]
    end

    def call_tool("test_ping", _args), do: {:ok, "pong"}
    def call_tool("test_error", _args), do: {:error, "simulated error"}
    def call_tool(_, _), do: {:error, "unknown tool"}
  end

  setup do
    {:ok, protocol: Protocol.new(TestHandler)}
  end

  test "initialize handshake" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2024-11-05", "capabilities" => %{}}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["id"] == 1
    assert resp["result"]["protocolVersion"] == "2024-11-05"
    assert resp["result"]["serverInfo"]["name"] == "mosaic-mcp"
  end

  test "tools/list returns tool definitions" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list",
      "params" => %{}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["id"] == 2
    assert length(resp["result"]["tools"]) == 1
    assert hd(resp["result"]["tools"])["name"] == "test_ping"
  end

  test "tools/call dispatches to handler" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "test_ping", "arguments" => %{}}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["id"] == 3
    assert length(resp["result"]["content"]) == 1
    assert hd(resp["result"]["content"])["text"] == "pong"
  end

  test "tools/call returns error for unknown tool" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{"name" => "nonexistent", "arguments" => %{}}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["id"] == 4
    assert resp["result"]["isError"] == true
  end

  test "ping returns empty result" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 5,
      "method" => "ping",
      "params" => %{}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["id"] == 5
    assert resp["result"] == %{}
  end

  test "unknown method returns error" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 6,
      "method" => "nonexistent_method",
      "params" => %{}
    })

    {:ok, resp_json, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["error"]["code"] == -32601
    assert String.contains?(resp["error"]["message"], "Method not found")
  end

  test "parse error returns JSON-RPC error" do
    {:error, resp_json, _} = Protocol.process_request("not valid json", Protocol.new(TestHandler))
    resp = Jason.decode!(resp_json)

    assert resp["error"]["code"] == -32700
    assert resp["error"]["message"] == "Parse error"
  end

  test "initialized notification returns nil" do
    req = Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "initialized",
      "params" => %{}
    })

    {:ok, nil, _state} = Protocol.process_request(req, Protocol.new(TestHandler))
  end
end

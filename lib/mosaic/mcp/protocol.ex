defmodule Mosaic.MCP.Protocol do
  @moduledoc """
  JSON-RPC 2.0 protocol handler for MCP (Model Context Protocol) over stdio.

  Implements the MCP transport layer: reading JSON-RPC requests from stdin,
  dispatching to tool handlers, and writing JSON-RPC responses to stdout.

  ## Wire Format

  Messages are newline-delimited JSON. The MCP stdio transport uses
  content-length prefixed messages OR bare newline-delimited JSON.
  We support both.

  ## Request Format (JSON-RPC 2.0)

      {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"mosaic_load","arguments":{"path":"lib/"}}}

  ## Response Format

      {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Loaded 45 files, 1823 nodes"}]}}
  """

  require Logger

  @jsonrpc_version "2.0"

  defstruct [:tool_handler, :server_info, :initialized]

  @doc "Build the initial server state."
  def new(tool_handler, server_info \\ default_server_info()) do
    %__MODULE__{
      tool_handler: tool_handler,
      server_info: server_info,
      initialized: false
    }
  end

  @doc """
  Process a single JSON-RPC request string and return the response string.
  Returns {:ok, response_json, new_state} | {:error, error_json, state}.
  """
  def process_request(json_str, state) do
    case Jason.decode(json_str) do
      {:ok, request} ->
        handle_request(request, state)

      {:error, _} ->
        error = error_response(nil, -32700, "Parse error", nil)
        {:error, Jason.encode!(error), state}
    end
  end

  # ── Request Dispatch ──────────────────────────────────────────

  defp handle_request(%{"method" => "initialize", "id" => id, "params" => _params}, state) do
    result = %{
      protocolVersion: "2024-11-05",
      capabilities: %{
        tools: %{}
      },
      serverInfo: state.server_info
    }

    response = success_response(id, result)
    {:ok, Jason.encode!(response), %{state | initialized: true}}
  end

  defp handle_request(%{"method" => "initialized"}, state) do
    # Notification — no response needed
    {:ok, nil, state}
  end

  defp handle_request(%{"method" => "tools/list", "id" => id}, state) do
    tools = state.tool_handler.list_tools()
    result = %{tools: tools}
    response = success_response(id, result)
    {:ok, Jason.encode!(response), state}
  end

  defp handle_request(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = Map.get(params, "name", "")
    arguments = Map.get(params, "arguments", %{})

    case state.tool_handler.call_tool(tool_name, arguments) do
      {:ok, content} ->
        result = %{content: ensure_content(content)}
        response = success_response(id, result)
        {:ok, Jason.encode!(response), state}

      {:error, reason} ->
        result = %{
          content: [%{type: "text", text: "Error: #{reason}"}],
          isError: true
        }
        response = success_response(id, result)
        {:ok, Jason.encode!(response), state}
    end
  end

  defp handle_request(%{"method" => "ping", "id" => id}, state) do
    response = success_response(id, %{})
    {:ok, Jason.encode!(response), state}
  end

  defp handle_request(%{"method" => method, "id" => id}, state) do
    Logger.warning("Unknown MCP method: #{method}")
    error = error_response(id, -32601, "Method not found: #{method}", nil)
    {:ok, Jason.encode!(error), state}
  end

  defp handle_request(%{"jsonrpc" => _} = _request, state) do
    # Notification without method field
    {:ok, nil, state}
  end

  defp handle_request(_malformed, state) do
    error = error_response(nil, -32600, "Invalid Request", nil)
    {:ok, Jason.encode!(error), state}
  end

  # ── Response Builders ─────────────────────────────────────────

  defp success_response(id, result) do
    %{
      jsonrpc: @jsonrpc_version,
      id: id,
      result: result
    }
  end

  defp error_response(id, code, message, data) do
    base = %{
      jsonrpc: @jsonrpc_version,
      id: id,
      error: %{
        code: code,
        message: message
      }
    }

    if data, do: put_in(base.error[:data], data), else: base
  end

  # ── Content Normalization ─────────────────────────────────────

  defp ensure_content(content) when is_list(content), do: content

  defp ensure_content(text) when is_binary(text) do
    [%{type: "text", text: text}]
  end

  defp ensure_content(map) when is_map(map) do
    [%{type: "text", text: Jason.encode!(map, pretty: true)}]
  end

  defp ensure_content(_), do: [%{type: "text", text: "ok"}]

  # ── Defaults ──────────────────────────────────────────────────

  defp default_server_info do
    %{
      name: "mosaic-mcp",
      version: "0.2.0"
    }
  end
end

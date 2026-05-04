defmodule Mosaic.MCP.Server do
  @moduledoc """
  MCP stdio server — GenServer that reads JSON-RPC from stdin,
  dispatches to tool handlers, and writes responses to stdout.

  ## Usage

      # As a standalone executable
      mix run -e 'Mosaic.MCP.Server.start()' --no-halt

      # Or start from the supervision tree
      {Mosaic.MCP.Server, []}

  ## MCP Client Configuration

  Add to your MCP client config (Claude, Cursor, etc.):

  ```json
  {
    "mcpServers": {
      "mosaic": {
        "command": "mosaic-mcp",
        "args": []
      }
    }
  }
  ```
  """

  use GenServer
  require Logger

  alias Mosaic.MCP.{Protocol, Tools}

  @name __MODULE__

  # ── Client API ─────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def start do
    GenServer.start(@name, nil, name: @name)
  end

  # ── GenServer Callbacks ───────────────────────────────────────

  def init(_opts) do
    protocol = Protocol.new(Tools)

    # Read stdin line by line in a separate task
    Task.start(fn -> read_loop() end)

    {:ok, %{protocol: protocol}}
  end

  def handle_info({:stdin_line, line}, %{protocol: protocol} = state) do
    trimmed = String.trim(line)

    if trimmed != "" do
      case Protocol.process_request(trimmed, protocol) do
        {:ok, nil, new_protocol} ->
          # Notification — no response
          {:noreply, %{state | protocol: new_protocol}}

        {:ok, response, new_protocol} ->
          write_line(response)
          {:noreply, %{state | protocol: new_protocol}}

        {:error, response, new_protocol} ->
          write_line(response)
          {:noreply, %{state | protocol: new_protocol}}
      end
    end
  end

  def handle_info({:stdin_closed}, state) do
    Logger.info("MCP stdin closed — shutting down")
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("MCP server unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Stdio I/O ──────────────────────────────────────────────────

  defp read_loop do
    case IO.read(:stdio, :line) do
      :eof ->
        send(@name, {:stdin_closed})

      {:error, reason} ->
        Logger.error("MCP stdin read error: #{inspect(reason)}")
        send(@name, {:stdin_closed})

      line ->
        send(@name, {:stdin_line, line})
        read_loop()
    end
  end

  defp write_line(line) do
    IO.puts(:stdio, line)
  end
end

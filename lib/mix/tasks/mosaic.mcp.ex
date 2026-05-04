defmodule Mix.Tasks.Mosaic.Mcp do
  @moduledoc """
  Start MosaicDB as an MCP (Model Context Protocol) stdio server.

  Reads JSON-RPC requests from stdin, dispatches to mosaic_* tools,
  and writes responses to stdout. Compatible with Claude Desktop,
  Cursor, and any MCP-capable agent.

  ## Usage

      mix mosaic.mcp

  ## MCP Client Configuration

  ```json
  {
    "mcpServers": {
      "mosaic": {
        "command": "mix",
        "args": ["mosaic.mcp"],
        "cwd": "/path/to/mosaic"
      }
    }
  }
  ```

  Or with a release:

  ```json
  {
    "mcpServers": {
      "mosaic": {
        "command": "/path/to/mosaic/bin/mosaic",
        "args": ["mcp"]
      }
    }
  }
  ```
  """

  use Mix.Task

  @shortdoc "Start MosaicDB as an MCP stdio server"

  def run(_args) do
    # Enable MCP mode
    Application.put_env(:mosaic, :mcp_enabled, true)
    Application.put_env(:mosaic, :mcp_transport, "stdio")

    # Redirect all Logger output to stderr (stdout is for JSON-RPC only)
    Logger.configure_backend(:console, device: :stderr)

    # Suppress inspect noise from startup
    Application.put_env(:mosaic, :startup_quiet, true)

    # Start the full application with MCP server
    {:ok, _apps} = Application.ensure_all_started(:mosaic)

    # Keep the process alive — the MCP server reads stdin in a Task
    Process.sleep(:infinity)
  end
end

defmodule Mosaic.A2A do
  @moduledoc """
  Agent-to-Agent (A2A) Agent Card for MosaicDB.

  Exposes a discoverable agent card at `/.well-known/agent.json` that
  describes MosaicDB's capabilities for direct agent orchestration.
  Weft agents and yas-mcp can discover and delegate tasks without
  going through an intermediary proxy.

  ## Agent Card Format

  Follows the A2A protocol spec (https://a2a-protocol.org):
  - Agent identity (name, version, description)
  - Capabilities (semantic actions the agent supports)
  - Endpoints (MCP, health, API)
  - Authentication requirements
  """

  @doc "Generate the A2A Agent Card."
  @spec agent_card() :: map()
  def agent_card do
    %{
      # ── Identity ──────────────────────────────────────
      name: "mosaicdb",
      version: "0.2.0",
      description: "Federated SQL Semantic Search & Analytics Engine with DuckDB, SQLite shards, Property Graph, RAG, and MCP server",
      url: "https://github.com/allen-munsch/mosaic",
      provider: %{
        name: "MosaicDB",
        url: "https://github.com/allen-munsch/mosaic"
      },

      # ── Capabilities ──────────────────────────────────
      capabilities: %{
        memory: %{
          store: true,
          recall: true,
          consolidate: true,
          stats: true
        },
        search: %{
          vector: true,
          hybrid: true,
          grounded: true,
          sql: true
        },
        graph: %{
          traverse: true,
          analytics: true,
          report: true
        },
        documents: %{
          index: true,
          delete: true
        },
        ingest: %{
          image: true,
          audio: true,
          youtube: true,
          media: true
        },
        pipelines: %{
          define: true,
          run: true,
          history: true
        },
        prompts: %{
          create: true,
          render: true,
          version: true,
          rollback: true
        },
        triggers: %{
          create: true,
          test: true,
          delete: true
        },
        cache: %{
          stats: true,
          purge: true
        }
      },

      # ── Endpoints ─────────────────────────────────────
      endpoints: %{
        mcp: "#{base_url()}/mcp",
        health: "#{base_url()}/health",
        api: "#{base_url()}/api",
        agent_card: "#{base_url()}/.well-known/agent.json"
      },

      # ── Protocols ─────────────────────────────────────
      protocols: %{
        mcp: %{
          version: "2024-11-05",
          transports: ["stdio", "http"]
        },
        a2a: %{
          version: "1.0",
          agent_card_path: "/.well-known/agent.json"
        }
      },

      # ── Authentication ────────────────────────────────
      auth: %{
        type: "bearer_jwt",
        public_endpoints: ["/health", "/mcp", "/.well-known/agent.json", "/api/auth/login"],
        docs: "POST /api/auth/login with username/password to obtain JWT"
      },

      # ── Default skills (for yas-mcp tool generation) ──
      default_skills: Mosaic.MCP.Tools.list_tools()
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          input_schema: tool.inputSchema
        }
      end),

      # ── Health ─────────────────────────────────────────
      health: %{
        endpoint: "/health",
        interval_seconds: 10
      }
    }
  end

  defp base_url do
    port = System.get_env("PORT", "4040")
    host = System.get_env("A2A_HOST", "localhost")
    scheme = if System.get_env("A2A_TLS") == "true", do: "https", else: "http"
    "#{scheme}://#{host}:#{port}"
  end
end

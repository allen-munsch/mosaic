#!/bin/bash
# ============================================================================
# Mosaic Search Engine - Simple Setup
# ============================================================================

set -e

echo "🎨 Setting up Mosaic Search Engine..."

# Create directories
mkdir -p lib/mosaic config priv test

# Create mix.exs
cat > mix.exs <<'EOF'
defmodule Mosaic.MixProject do
  use Mix.Project

  def project do
    [
      app: :mosaic,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :crypto],
      mod: {Mosaic.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:plug, "~> 1.15"},
      {:jason, "~> 1.4"}
    ]
  end

  defp releases do
    [
      mosaic: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end
end
EOF

# Create application
cat > lib/mosaic/application.ex <<'EOF'
defmodule Mosaic.Application do
  use Application
  require Logger

  def start(_type, _args) do
    port = System.get_env("PORT", "4040") |> String.to_integer()
    Logger.info("Starting Mosaic on port #{port}")
    
    children = [
      {Plug.Cowboy, scheme: :http, plug: Mosaic.Router, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mosaic.Supervisor)
  end
end

defmodule Mosaic.Router do
  use Plug.Router
  
  plug Plug.Logger
  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "healthy\n")
  end

  get "/api/status" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{
      status: "ok",
      version: "0.1.0",
      name: "Mosaic",
      tagline: "Fractal intelligence, assembled"
    }))
  end

  match _ do
    send_resp(conn, 404, "Not found\n")
  end
end
EOF

# Create config
cat > config/config.exs <<'EOF'
import Config
config :logger, level: :info
import_config "#{config_env()}.exs"
EOF

cat > config/dev.exs <<'EOF'
import Config
config :logger, level: :debug
EOF

cat > config/prod.exs <<'EOF'
import Config
config :logger, level: :info
EOF

cat > config/test.exs <<'EOF'
import Config
config :logger, level: :warn
EOF

# Create empty mix.lock
touch mix.lock

# Create .gitignore
cat > .gitignore <<'EOF'
/_build/
/deps/
*.ez
.elixir_ls/
.env
/data/
EOF

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  mix deps.get          # Install dependencies"
echo "  mix run --no-halt     # Run locally"
echo ""
echo "Or use Docker:"
echo "  docker-compose up"
echo ""

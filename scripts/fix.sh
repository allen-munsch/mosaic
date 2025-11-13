#!/bin/bash
# ============================================================================
# Mosaic Search Engine - Automated Fix Script
# ============================================================================

set -e

echo "🔧 Mosaic Search Engine - Automated Fix"
echo "========================================"
echo ""

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found"
    echo "Please run this script from the project root directory"
    exit 1
fi

echo "✅ Found docker-compose.yml"
echo ""

# Function to create file if it doesn't exist
create_if_missing() {
    local file=$1
    local content=$2
    
    if [ -f "$file" ]; then
        echo "  ✓ $file exists"
    else
        echo "  📝 Creating $file"
        mkdir -p "$(dirname "$file")"
        echo "$content" > "$file"
    fi
}

echo "📁 Checking project structure..."

# Create directories
mkdir -p lib/mosaic config priv test

# Check and create mix.exs
if [ ! -f "mix.exs" ]; then
    echo "  📝 Creating mix.exs"
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
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.19"},
      {:libcluster, "~> 3.3"}
    ]
  end

  defp releases do
    [
      mosaic: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar]
      ]
    ]
  end
end
EOF
else
    echo "  ✓ mix.exs exists"
fi

# Create mix.lock if missing
if [ ! -f "mix.lock" ]; then
    echo "  📝 Creating empty mix.lock"
    touch mix.lock
else
    echo "  ✓ mix.lock exists"
fi

# Check and create lib/mosaic/application.ex
if [ ! -f "lib/mosaic/application.ex" ]; then
    echo "  📝 Creating lib/mosaic/application.ex"
    cat > lib/mosaic/application.ex <<'EOF'
defmodule Mosaic.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4040") |> String.to_integer()
    Logger.info("Starting Mosaic on port #{port}")
    
    children = [
      {Plug.Cowboy, scheme: :http, plug: Mosaic.Router, options: [port: port]}
    ]

    opts = [strategy: :one_for_one, name: Mosaic.Supervisor]
    Supervisor.start_link(children, opts)
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
      name: "Mosaic Search Engine"
    }))
  end

  match _ do
    send_resp(conn, 404, "Not found\n")
  end
end
EOF
else
    echo "  ✓ lib/mosaic/application.ex exists"
fi

# Check and create config files
if [ ! -f "config/config.exs" ]; then
    echo "  📝 Creating config/config.exs"
    cat > config/config.exs <<'EOF'
import Config

config :mosaic,
  port: System.get_env("PORT", "4040")

config :logger, level: :info

import_config "#{config_env()}.exs"
EOF
else
    echo "  ✓ config/config.exs exists"
fi

if [ ! -f "config/dev.exs" ]; then
    echo "  📝 Creating config/dev.exs"
    echo "import Config" > config/dev.exs
    echo "config :logger, level: :debug" >> config/dev.exs
else
    echo "  ✓ config/dev.exs exists"
fi

if [ ! -f "config/prod.exs" ]; then
    echo "  📝 Creating config/prod.exs"
    echo "import Config" > config/prod.exs
    echo "config :logger, level: :info" >> config/prod.exs
else
    echo "  ✓ config/prod.exs exists"
fi

if [ ! -f "config/test.exs" ]; then
    echo "  📝 Creating config/test.exs"
    echo "import Config" > config/test.exs
    echo "config :logger, level: :warn" >> config/test.exs
else
    echo "  ✓ config/test.exs exists"
fi

# Create .gitkeep in priv if it's empty
if [ ! "$(ls -A priv)" ]; then
    touch priv/.gitkeep
    echo "  📝 Created priv/.gitkeep"
fi

echo ""
echo "✅ All required files created!"
echo ""

# Test if we can build
echo "🔨 Testing Docker build..."
if docker-compose build coordinator 2>&1 | grep -q "ERROR"; then
    echo "❌ Docker build failed"
    echo "Check the error messages above"
    exit 1
else
    echo "✅ Docker build successful!"
fi

echo ""
echo "🎉 Everything is ready!"
echo ""
echo "Next steps:"
echo "  1. Start services: docker-compose up -d"
echo "  2. Check status:   docker-compose ps"
echo "  3. View logs:      docker-compose logs -f"
echo "  4. Test API:       curl http://localhost/health"
echo ""
echo "Or use the Makefile:"
echo "  make up"
echo "  make status"
echo "  make logs"
echo ""

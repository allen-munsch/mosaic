#!/bin/bash
# Mosaic - Minimal Project Initialization

set -e

echo "🎨 Initializing Mosaic Search Engine"
echo ""

# Create directory structure
echo "Creating directories..."
mkdir -p lib/mosaic
mkdir -p config
mkdir -p priv
mkdir -p scripts
mkdir -p docs

# Create mix.exs
echo "Creating mix.exs..."
cat > mix.exs <<'EOF'
defmodule Mosaic.MixProject do
  use Mix.Project

  def project do
    [
      app: :mosaic,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Mosaic.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"}
    ]
  end
end
EOF

touch mix.lock

# Create application
echo "Creating application..."
cat > lib/mosaic/application.ex <<'EOF'
defmodule Mosaic.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Plug.Cowboy, 
       scheme: :http, 
       plug: Mosaic.Router, 
       options: [port: 4040]}
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Mosaic.Router do
  use Plug.Router
  
  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
EOF

# Create config
echo "Creating config..."
cat > config/config.exs <<'EOF'
import Config
config :logger, level: :info
EOF

# Create Dockerfile
echo "Creating Dockerfile..."
cat > Dockerfile <<'EOF'
FROM elixir:1.16-alpine AS build
RUN apk add --no-cache build-base git
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
COPY lib ./lib
COPY config ./config
COPY priv ./priv
RUN mix release

FROM alpine:3.19
RUN apk add --no-cache openssl ncurses-libs bash
WORKDIR /app
COPY --from=build /app/_build/prod/rel/mosaic ./
CMD ["bin/mosaic", "start"]
EOF

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
cat > docker-compose.yml <<'EOF'
services:
  mosaic:
    build: .
    ports:
      - "4040:4040"
    environment:
      - PORT=4040
EOF

# Create .gitignore
cat > .gitignore <<'EOF'
/_build
/deps
*.beam
.elixir_ls
EOF

# Create README
cat > README.md <<'EOF'
# Mosaic

Semantic search engine using SQLite shards.

## Run

```bash
mix deps.get
mix run --no-halt
```

Or with Docker:

```bash
docker-compose up
```

## Test

```bash
curl http://localhost:4040/health
```
EOF

echo ""
echo "✅ Done!"
echo ""
echo "Next steps:"
echo "  mix deps.get"
echo "  mix run --no-halt"
echo ""
echo "Or:"
echo "  docker-compose up"

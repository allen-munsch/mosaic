# ── Builder Stage ──────────────────────────────────────────────
FROM elixir:1.18.3 AS builder

ENV MIX_ENV=prod
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git curl cmake libstdc++-12-dev \
    python3 python3-pip nodejs npm \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copy sqlite-vec extension to priv/ for release bundling
RUN mkdir -p priv/sqlite_vec && \
    cp deps/sqlite_vec/priv/0.1.5/vec0.so priv/sqlite_vec/vec0.so 2>/dev/null || true

COPY config config/
COPY lib lib/
COPY priv priv/

RUN mix compile
RUN mix release mosaic --overwrite

# ── Runtime Stage ──────────────────────────────────────────────
FROM debian:bookworm-slim

ENV LANG=C.UTF-8
ENV PORT=4040
ENV MIX_ENV=prod

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libstdc++6 curl poppler-utils \
    python3 python3-pip nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install ast-grep (optional, fallback parser)
RUN npm install -g @ast-grep/cli 2>/dev/null || true

RUN groupadd -r mosaic && useradd -r -g mosaic -d /var/lib/mosaic mosaic

COPY --from=builder /app/_build/prod/rel/mosaic /app
RUN chown -R mosaic:mosaic /app

RUN mkdir -p /var/lib/mosaic/shards /var/lib/mosaic/config /var/lib/mosaic/data
RUN chown -R mosaic:mosaic /var/lib/mosaic

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

VOLUME ["/var/lib/mosaic/shards", "/var/lib/mosaic/config"]

EXPOSE 4040

USER mosaic
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["start"]

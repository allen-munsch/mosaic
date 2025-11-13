FROM elixir:1.16-alpine

# Install runtime dependencies
RUN apk add --no-cache \
    build-base \
    git \
    sqlite \
    curl \
    bash

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set working directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./

# Install dependencies
ENV MIX_ENV=dev
RUN mix deps.get

# Copy application code
COPY config ./config
COPY lib ./lib
COPY priv ./priv

# Compile
RUN mix compile

# Expose port
EXPOSE 4040

# Run with mix (no release needed)
CMD ["mix", "run", "--no-halt"]
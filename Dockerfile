# Use the specified Elixir image as base
FROM elixir:1.19.3-otp-28-slim

# Install necessary system dependencies
# build-essential for compilation tools, git for mix deps that might be from git,
# sqlite3 for the SQLite client (useful for debugging inside the container)
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    sqlite3 \
    curl \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/root/.cargo/bin:$PATH"

# Set the working directory inside the container
WORKDIR /app

# Copy the application code
COPY . /app

# Install Elixir dependencies and compile the project
# Use --force to ensure recompilation if needed
# mix ecto.create and mix ecto.migrate are placeholders if you have Ecto setup
RUN mix deps.get --only prod && \
    mix deps.compile sqlite_vec && \
    mix deps.compile duckdbex && \
    mix compile

# Expose the port your application runs on
EXPOSE 4040

# Define the command to run your application
CMD ["mix", "run", "--no-halt"]
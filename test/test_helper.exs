ExUnit.start()
ExUnit.configure(exclude: [:redis, :slow])

# Enable sync indexing for tests
Application.put_env(:mosaic, :sync_indexing, true)

# Load support files
Path.wildcard("test/support/**/*.ex") |> Enum.each(&Code.require_file/1)

# Start app
Application.stop(:mosaic)
Application.ensure_all_started(:mosaic, :permanent)
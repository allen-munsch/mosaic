ExUnit.start()
ExUnit.configure(exclude: :redis)

# Load support files
Path.wildcard("test/support/**/*.ex") |> Enum.each(&Code.require_file/1)

# Stop app if running, then start in permanent mode for tests
Application.stop(:mosaic)
Application.ensure_all_started(:mosaic, :permanent)


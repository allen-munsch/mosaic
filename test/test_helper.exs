# Configure ExUnit
ExUnit.start()
Application.ensure_all_started(:mox)

# Setup Mox for mocking
Mox.defmock(Mosaic.QueryEngineMock, for: Mosaic.QueryEngine.Behaviour)
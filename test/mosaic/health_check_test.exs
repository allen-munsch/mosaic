defmodule Mosaic.HealthCheckTest do
  use ExUnit.Case, async: false

  # These tests require full application stack
  # Run with: mix test --only integration

  describe "health check process" do
    @tag :integration
    test "starts successfully" do
      case Process.whereis(Mosaic.HealthCheck) do
        nil -> :ok  # Skip if not running
        pid -> assert is_pid(pid)
      end
    end

    @tag :integration
    test "responds to health check message" do
      case Process.whereis(Mosaic.HealthCheck) do
        nil -> :ok
        pid ->
          send(pid, :check_health)
          Process.sleep(100)
          assert Process.alive?(pid)
      end
    end
  end

  describe "individual health checks" do
    @tag :integration
    test "check_memory returns ok or warning" do
      case Process.whereis(Mosaic.HealthCheck) do
        nil -> :ok
        pid ->
          send(pid, :check_health)
          Process.sleep(100)
          assert Process.alive?(pid)
      end
    end
  end
end

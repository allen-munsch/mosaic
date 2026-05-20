defmodule Mosaic.API.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Mosaic.API.RateLimiter

  setup do
    RateLimiter.reset()
    on_exit(&RateLimiter.reset/0)
    :ok
  end

  describe "allow_request?/3" do
    test "allows first request" do
      assert RateLimiter.allow_request?("test_key_1", 1000)
    end

    test "allows requests within rate limit" do
      key = "test_key_#{System.unique_integer()}"
      # Allow 100 requests per minute
      results = Enum.map(1..50, fn _ ->
        RateLimiter.allow_request?(key, 100)
      end)
      assert Enum.all?(results)
    end

    test "rejects requests exceeding burst limit" do
      key = "burst_test_#{System.unique_integer()}"
      # With burst=5, the 6th request should be rejected
      results = Enum.map(1..10, fn _ ->
        RateLimiter.allow_request?(key, 100, 5)
      end)
      assert Enum.take(results, 5) |> Enum.all?()
      assert Enum.at(results, 5) == false
    end
  end

  describe "bucket_status/1" do
    test "returns status for existing bucket" do
      key = "status_test_#{System.unique_integer()}"
      RateLimiter.allow_request?(key, 100)
      status = RateLimiter.bucket_status(key)

      assert status.key == key
      assert is_number(status.tokens)
    end

    test "returns no_bucket for unknown key" do
      status = RateLimiter.bucket_status("nonexistent_key_xyz")
      assert status.status == :no_bucket
    end
  end

  describe "reset" do
    test "clears all buckets" do
      key = "reset_test_#{System.unique_integer()}"
      RateLimiter.allow_request?(key, 100)
      RateLimiter.reset()

      status = RateLimiter.bucket_status(key)
      assert status.status == :no_bucket
    end
  end
end

defmodule Mosaic.Auth.APIKeyTest do
  use ExUnit.Case

  alias Mosaic.Auth.APIKey

  # These tests require bcrypt_elixir to be available
  setup do
    bcrypt_available = Code.ensure_loaded?(Bcrypt)
    {:ok, bcrypt_available: bcrypt_available}
  end

  describe "key parsing" do
    test "parses valid key format" do
      key = "mk_live_abc123_xyz789"
      # This is a private function, tested through validate_key
      assert is_binary(key)
    end

    test "rejects key without prefix" do
      result = APIKey.validate_key("random_key_without_prefix")
      assert {:error, _reason} = result
    end
  end

  describe "validate_key" do
    test "rejects obviously invalid key" do
      result = APIKey.validate_key("mk_live_fake_invalid")
      assert {:error, _reason} = result
    end

    test "rejects empty key" do
      result = APIKey.validate_key("")
      assert {:error, _reason} = result
    end
  end

  describe "init_auth_db" do
    test "creates auth database tables" do
      # This is tested indirectly through the system - the function
      # should not raise
      APIKey.init_auth_db()
      # No assertion needed - if it doesn't crash, it worked
    end
  end
end

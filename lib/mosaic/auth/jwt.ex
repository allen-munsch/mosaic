defmodule Mosaic.Auth.JWT do
  @moduledoc """
  JWT-based authentication for MosaicDB HTTP API and MCP server.

  Provides token generation, validation, and scope-based authorization.
  Uses HMAC-SHA256 directly (no joken dependency needed).

  ## Usage

      # Generate a token
      {:ok, token, claims} = Mosaic.Auth.JWT.generate_token("user_123", ["read", "write"])

      # Verify a token
      {:ok, claims} = Mosaic.Auth.JWT.verify_token(token)

      # Check scopes
      Mosaic.Auth.JWT.has_scope?(claims, "write")
  """

  require Logger

  @type token :: String.t()
  @type claims :: %{String.t() => term()}
  @type scope :: String.t()
  @type user_id :: String.t()

  @default_ttl 86_400  # 24 hours
  @header %{"alg" => "HS256", "typ" => "JWT"}

  @doc "Generate a JWT token for a user/tenant."
  @spec generate_token(user_id(), [scope()], keyword()) :: {:ok, token(), claims()}
  def generate_token(user_id, scopes, opts \\ []) when is_binary(user_id) and is_list(scopes) do
    ttl = Keyword.get(opts, :ttl, configured_ttl())
    now = DateTime.utc_now() |> DateTime.to_unix()
    exp = now + ttl

    claims = %{
      "sub" => user_id,
      "scope" => Enum.join(scopes, " "),
      "iat" => now,
      "exp" => exp,
      "iss" => Keyword.get(opts, :issuer, configured_issuer()),
      "aud" => Keyword.get(opts, :audience, configured_audience()),
      "jti" => generate_jti()
    }

    token = sign(claims, configured_secret())
    {:ok, token, claims}
  end

  @doc "Verify a JWT token and return claims."
  @spec verify_token(token()) :: {:ok, claims()} | {:error, :invalid_token | :no_scopes}
  def verify_token(token) when is_binary(token) do
    case verify(token, configured_secret()) do
      {:ok, claims} ->
        verify_scopes(claims)

      {:error, reason} ->
        Logger.debug("JWT verification failed: #{inspect(reason)}")
        {:error, :invalid_token}
    end
  end

  @doc "Check if a verified claims map has a required scope."
  @spec has_scope?(claims(), scope()) :: boolean()
  def has_scope?(claims, required_scope) when is_binary(required_scope) do
    scopes = String.split(Map.get(claims, "scope", ""), " ")
    required_scope in scopes or "admin" in scopes
  end

  @doc "Get the user/tenant ID from claims."
  @spec subject(claims()) :: user_id() | nil
  def subject(claims) do
    Map.get(claims, "sub")
  end

  @doc "Get the scopes from claims."
  @spec scopes(claims()) :: [scope()]
  def scopes(claims) do
    Map.get(claims, "scope", "")
    |> String.split(" ")
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Extract token from Authorization header."
  @spec extract_token(String.t() | nil) :: {:ok, token()} | {:error, :invalid_header | :missing_header}
  def extract_token(header) when is_binary(header) do
    case String.split(header, " ") do
      ["Bearer", token] -> {:ok, token}
      _ -> {:error, :invalid_header}
    end
  end

  def extract_token(nil), do: {:error, :missing_header}

  # ── HMAC-SHA256 JWT Implementation ────────────────────────

  defp sign(claims, secret) do
    header_b64 = encode_json(@header)
    payload_b64 = encode_json(claims)
    signing_input = "#{header_b64}.#{payload_b64}"
    signature = hmac_sha256(signing_input, secret)
    "#{signing_input}.#{signature}"
  end

  defp verify(token, secret) do
    case String.split(token, ".", parts: 3) do
      [header_b64, payload_b64, signature_b64] ->
        signing_input = "#{header_b64}.#{payload_b64}"
        expected_sig = hmac_sha256(signing_input, secret)

        if secure_compare(signature_b64, expected_sig) do
          case Base.url_decode64(payload_b64, padding: false) do
            {:ok, json} ->
              case Jason.decode(json) do
                {:ok, claims} ->
                  # Check expiration
                  exp = Map.get(claims, "exp", 0)
                  now = DateTime.utc_now() |> DateTime.to_unix()

                  if exp > now do
                    {:ok, claims}
                  else
                    {:error, :token_expired}
                  end

                {:error, _} ->
                  {:error, :invalid_payload}
              end

            :error ->
              {:error, :invalid_payload}
          end
        else
          {:error, :invalid_signature}
        end

      _ ->
        {:error, :invalid_token_format}
    end
  end

  defp encode_json(map) do
    map
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp hmac_sha256(data, secret) do
    :crypto.mac(:hmac, :sha256, secret, data)
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_a, _b), do: false

  # ── Private ────────────────────────────────────────────────

  defp verify_scopes(claims) do
    scopes = Map.get(claims, "scope", "")
    case scopes do
      "" -> {:error, :no_scopes}
      _ -> {:ok, claims}
    end
  end

  defp generate_jti do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp configured_secret do
    Mosaic.Config.get(:jwt_secret, "mosaic-dev-secret-change-in-production")
  end

  defp configured_issuer do
    Mosaic.Config.get(:jwt_issuer, "mosaicdb")
  end

  defp configured_audience do
    Mosaic.Config.get(:jwt_audience, "mosaicdb-api")
  end

  defp configured_ttl do
    Mosaic.Config.get(:jwt_ttl, @default_ttl)
  end
end

defmodule Mosaic.Auth.JWT do
  @moduledoc """
  JWT-based authentication for MosaicDB HTTP API and MCP server.

  Provides token generation, validation, and scope-based authorization.
  Uses joken for JWT operations with HS256 (HMAC-SHA256) by default.

  ## Usage

      # Generate a token
      {:ok, token, claims} = Mosaic.Auth.JWT.generate_token("user_123", ["read", "write"])

      # Verify a token
      {:ok, claims} = Mosaic.Auth.JWT.verify_token(token)

      # Check scopes
      Mosaic.Auth.JWT.has_scope?(claims, "write")
  """

  require Logger

  @default_algorithm "HS256"
  @default_ttl 86_400  # 24 hours

  @doc "Generate a JWT token for a user/tenant."
  @spec generate_token(String.t(), [String.t()], keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
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

    signer = joken_signer()

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _claims} -> {:ok, token, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Verify a JWT token and return claims."
  @spec verify_token(String.t()) :: {:ok, map()} | {:error, :invalid_token}
  def verify_token(token) when is_binary(token) do
    signer = joken_signer()

    with {:ok, claims} <- Joken.verify(token, signer),
         :ok <- validate_claims(claims) do
      verify_scopes(claims)
    else
      {:error, reason} ->
        Logger.debug("JWT verification failed: #{inspect(reason)}")
        {:error, :invalid_token}
    end
  end

  @doc "Check if a verified claims map has a required scope."
  @spec has_scope?(map(), String.t()) :: boolean()
  def has_scope?(claims, required_scope) when is_binary(required_scope) do
    scopes = String.split(Map.get(claims, "scope", ""), " ")
    required_scope in scopes or "admin" in scopes
  end

  @doc "Get the user/tenant ID from claims."
  @spec subject(map()) :: String.t() | nil
  def subject(claims) do
    Map.get(claims, "sub")
  end

  @doc "Get the scopes from claims."
  @spec scopes(map()) :: [String.t()]
  def scopes(claims) do
    Map.get(claims, "scope", "")
    |> String.split(" ")
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Extract token from Authorization header."
  @spec extract_token(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_header | :missing_header}
  def extract_token(header) when is_binary(header) do
    case String.split(header, " ") do
      ["Bearer", token] -> {:ok, token}
      _ -> {:error, :invalid_header}
    end
  end

  def extract_token(nil), do: {:error, :missing_header}

  # ── Private ────────────────────────────────────────────────

  defp joken_signer do
    secret = configured_secret()
    Joken.Signer.create(@default_algorithm, secret)
  end

  defp validate_claims(claims) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    exp = Map.get(claims, "exp")
    iss = Map.get(claims, "iss")

    cond do
      is_integer(exp) and exp < now -> {:error, :expired}
      iss != nil and iss != configured_issuer() -> {:error, :invalid_issuer}
      true -> :ok
    end
  end

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

defmodule Mosaic.Auth.Plug do
  @moduledoc """
  Plug for authenticating requests to the MosaicDB HTTP API.

  Supports two authentication methods:
  1. Bearer JWT tokens (Authorization: Bearer <jwt>)
  2. API keys (X-API-Key: mk_live_...)

  Adds :auth_claims to the Plug.Conn assigns on success.
  Returns 401 on failure.

  ## Usage in a Router

      pipeline :api do
        plug :accepts, ["json"]
        plug Mosaic.Auth.Plug
      end
  """

  import Plug.Conn

  require Logger

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, claims} ->
        conn
        |> assign(:auth_claims, claims)
        |> assign(:authenticated, true)

      {:error, reason} ->
        Logger.debug("Auth failed: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{
          error: "unauthorized",
          detail: reason_to_string(reason)
        }))
        |> halt()
    end
  end

  @doc "Manually authenticate a connection. Returns {:ok, claims} or {:error, reason}."
  def authenticate(conn) do
    # Try API key first (takes precedence)
    case get_req_header(conn, "x-api-key") do
      [key | _] ->
        Mosaic.Auth.APIKey.validate_key(key)

      _ ->
        # Try Bearer token
        case get_req_header(conn, "authorization") do
          [header | _] ->
            with {:ok, token} <- Mosaic.Auth.JWT.extract_token(header),
                 {:ok, claims} <- Mosaic.Auth.JWT.verify_token(token) do
              {:ok, %{
                sub: Mosaic.Auth.JWT.subject(claims),
                scopes: Mosaic.Auth.JWT.scopes(claims),
                tenant_id: Mosaic.Auth.JWT.subject(claims),
                auth_method: "jwt"
              }}
            end

          [] ->
            {:error, :no_credentials}
        end
    end
  end

  @doc "Check if the authenticated connection has a required scope."
  def require_scope(conn, scope) do
    claims = conn.assigns[:auth_claims]

    if claims && scope in claims[:scopes] do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{
        error: "forbidden",
        detail: "Missing required scope: #{scope}"
      }))
      |> halt()
    end
  end

  defp reason_to_string(:no_credentials), do: "No authentication credentials provided"
  defp reason_to_string(:invalid_key), do: "Invalid API key or JWT token"
  defp reason_to_string(:unknown_key), do: "Unknown API key"
  defp reason_to_string(:invalid_header), do: "Invalid Authorization header format"
  defp reason_to_string(:invalid_token), do: "Invalid or expired JWT token"
  defp reason_to_string(:no_scopes), do: "Token has no authorized scopes"
  defp reason_to_string(_), do: "Authentication failed"
end

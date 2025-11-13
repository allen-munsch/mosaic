defmodule Mosaic.Search do
  def search(query) do
    [%{id: 1, text: "Result for #{query}"}]
  end
end

defmodule Mosaic.WebApplication do
  use Application
  require Logger

  def start(_type, _args) do
    port = System.get_env("PORT", "4040") |> String.to_integer()
    Logger.info("Starting Mosaic on port #{port}")
    
    children = [
      {Plug.Cowboy, scheme: :http, plug: Mosaic.Router, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Mosaic.Supervisor)
  end
end

defmodule Mosaic.Router do
  use Plug.Router
  
  plug Plug.Logger
  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "healthy\n")
  end

  get "/api/status" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{
      status: "ok",
      version: "0.1.0",
      name: "Mosaic",
      tagline: "Fractal intelligence, assembled"
    }))
  end

  post "/search" do
    query = conn.body_params["query"]
    results = Mosaic.Search.search(query)
    
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(results))
  end

  match _ do
    send_resp(conn, 404, "Not found\n")
  end
end

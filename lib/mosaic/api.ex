defmodule Mosaic.API do
  use Plug.Router
  require Logger

  plug :parse_body
  plug Plug.Logger
  plug :match
  plug :dispatch

  def start_link(opts) do
    Plug.Cowboy.child_spec(scheme: :http, plug: __MODULE__, options: opts)
  end

  defp parse_body(conn, _opts) do
    case Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], pass: ["application/json"], json_decoder: Jason)) do
      conn -> conn
    end
  rescue
    Plug.Parsers.ParseError ->
      conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: "Invalid JSON"})) |> halt()
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  post "/api/search" do
    case conn.body_params do
      %{"query" => query} when is_binary(query) and byte_size(query) > 0 ->
        opts = extract_search_opts(conn.body_params)
        results = Mosaic.Search.perform_search(query, opts)
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{results: results}))
      %{"query" => ""} ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: "Query cannot be empty"}))
      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: "Missing or invalid query parameter"}))
    end
  end

  post "/api/index" do
    case conn.body_params do
      %{"text" => text, "id" => id} when is_binary(text) ->
        metadata = Map.get(conn.body_params, "metadata", %{})
        {:ok, result} = Mosaic.Indexer.index_document(id, text, metadata)
        conn |> put_resp_content_type("application/json") |> send_resp(201, Jason.encode!(%{id: id, shard_id: result.shard_id, status: "indexed"}))
      %{"documents" => docs} when is_list(docs) ->
        documents = Enum.map(docs, fn d -> {d["id"], d["text"], Map.get(d, "metadata", %{})} end)
        case Mosaic.Indexer.index_documents(documents) do
          {:ok, result} ->
            conn |> put_resp_content_type("application/json") |> send_resp(201, Jason.encode!(result))
          {:error, reason} ->
            conn |> put_resp_content_type("application/json") |> send_resp(500, Jason.encode!(%{error: inspect(reason)}))
        end
      _ ->
        conn |> put_resp_content_type("application/json") |> send_resp(400, Jason.encode!(%{error: "Missing text/id or documents parameter"}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp extract_search_opts(params) do
    []
    |> maybe_add_opt(params, "limit", :limit, &String.to_integer/1)
    |> maybe_add_opt(params, "min_similarity", :min_similarity, &String.to_float/1)
  end

  defp maybe_add_opt(opts, params, key, opt_key, converter) do
    case Map.get(params, key) do
      nil -> opts
      value when is_binary(value) -> Keyword.put(opts, opt_key, converter.(value))
      value when is_integer(value) or is_float(value) -> Keyword.put(opts, opt_key, value)
    end
  end
end

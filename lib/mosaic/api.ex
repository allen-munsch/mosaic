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
    Plug.Parsers.call(conn, Plug.Parsers.init(
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    ))
  rescue
    Plug.Parsers.ParseError ->
      conn |> json_error(400, "Invalid JSON") |> halt()
  end

  # Health
  get "/health" do
    send_resp(conn, 200, "ok")
  end

  # HOT PATH: Semantic search
  post "/api/search" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      opts = extract_search_opts(conn.body_params)
      results = Mosaic.QueryRouter.execute(query, [], Keyword.put(opts, :force_engine, :vector_search))
      json_ok(conn, %{results: results, path: "hot"})
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # HOT PATH: Hybrid search (vector + SQL filter)
  post "/api/search/hybrid" do
    with {:ok, query} <- require_param(conn.body_params, "query") do
      opts = extract_search_opts(conn.body_params)
      where = Map.get(conn.body_params, "where")
      results = Mosaic.HybridQuery.search(query, Keyword.put(opts, :where, where))
      json_ok(conn, %{results: results, path: "hot"})
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # WARM PATH: SQL analytics (auto-routed)
  post "/api/query" do
    with {:ok, sql} <- require_param(conn.body_params, "sql") do
      params = Map.get(conn.body_params, "params", [])

      case Mosaic.QueryRouter.execute(sql, params) do
        {:ok, results} -> json_ok(conn, %{results: results})
        {:error, reason} -> json_error(conn, 500, inspect(reason))
        results when is_list(results) -> json_ok(conn, %{results: results})
        result -> json_ok(conn, %{result: result})
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # WARM PATH: Explicit analytics endpoint
  post "/api/analytics" do
    with {:ok, sql} <- require_param(conn.body_params, "sql") do
      params = Map.get(conn.body_params, "params", [])

      case Mosaic.DuckDBBridge.query(sql, params) do
        {:ok, results} -> json_ok(conn, %{results: results, path: "warm", engine: "duckdb"})
        {:error, reason} -> json_error(conn, 500, inspect(reason))
      end
    else
      {:error, msg} -> json_error(conn, 400, msg)
    end
  end

  # Indexing
  post "/api/documents" do
    case conn.body_params do
      %{"text" => text, "id" => id} ->
        metadata = Map.get(conn.body_params, "metadata", %{})
        {:ok, result} = Mosaic.Indexer.index_document(id, text, metadata)
        json_ok(conn, 201, %{id: result.id, status: result.status})

      %{"documents" => docs} when is_list(docs) ->
        documents = Enum.map(docs, fn d -> {d["id"], d["text"], Map.get(d, "metadata", %{})} end)
        case Mosaic.Indexer.index_documents(documents) do
          {:ok, result} -> json_ok(conn, 201, result)
          {:error, reason} -> json_error(conn, 500, inspect(reason))
        end

      _ ->
        json_error(conn, 400, "Missing text/id or documents")
    end
  end

  get "/api/shards" do
    shards = Mosaic.ShardRouter.list_all_shards()
    |> Enum.map(fn shard ->
      shard
      |> Map.drop([:centroid, :centroid_norm])
      |> Map.take([:id, :path, :doc_count, :query_count])
    end)
    json_ok(conn, %{shards: shards, count: length(shards)})
  end


  post "/api/admin/refresh-duckdb" do
    Mosaic.DuckDBBridge.refresh_shards()
    json_ok(conn, %{status: "refreshed"})
  end

  get "/api/metrics" do
    metrics = %{
      cache_hits: Mosaic.EmbeddingCache.get_metrics().hits,
      cache_misses: Mosaic.EmbeddingCache.get_metrics().misses,
      shard_count: length(Mosaic.ShardRouter.list_all_shards()),
      duckdb_shards: length(Mosaic.DuckDBBridge.attached_shards())
    }
    json_ok(conn, metrics)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # Helpers

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "Missing required parameter: #{key}"}
      "" -> {:error, "#{key} cannot be empty"}
      val -> {:ok, val}
    end
  end

  defp extract_search_opts(params) do
    []
    |> add_opt(params, "limit", :limit, &parse_int/1)
    |> add_opt(params, "min_similarity", :min_similarity, &parse_float/1)
    |> add_opt(params, "shard_limit", :shard_limit, &parse_int/1)
  end

  defp add_opt(opts, params, key, opt_key, parser) do
    case Map.get(params, key) do
      nil -> opts
      val -> Keyword.put(opts, opt_key, parser.(val))
    end
  end

  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v), do: String.to_integer(v)

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_binary(v), do: String.to_float(v)

  defp json_ok(conn, body), do: json_ok(conn, 200, body)
  defp json_ok(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end
end

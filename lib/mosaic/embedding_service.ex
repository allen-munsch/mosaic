defmodule Mosaic.EmbeddingService do
  use GenServer
  require Logger
  @timeout 5_000

  @type embedding :: [float()]
  @type model_name :: String.t()
  @type model_config :: %{dim: integer(), source: atom(), model: String.t()}

  defp zero_embedding, do: List.duplicate(0.0, Mosaic.Config.get(:embedding_dim, 384))

  defmodule State do
    @type t :: %__MODULE__{
      model_type: String.t(),
      model_ref: map() | atom(),
      model_name: String.t(),
      dimension: integer()
    }
    defstruct [:model_type, :model_ref, :model_name, :dimension]
  end

  @doc "Supported embedding model configurations."
  @spec models() :: %{String.t() => model_config()}
  def models do
    %{
      "all-MiniLM-L6-v2" => %{dim: 384, source: :huggingface, model: "sentence-transformers/all-MiniLM-L6-v2"},
      "all-mpnet-base-v2" => %{dim: 768, source: :huggingface, model: "sentence-transformers/all-mpnet-base-v2"},
      "e5-large-v2" => %{dim: 1024, source: :huggingface, model: "intfloat/e5-large-v2"},
      "text-embedding-3-small" => %{dim: 1536, source: :openai, model: "text-embedding-3-small"},
      "text-embedding-3-large" => %{dim: 3072, source: :openai, model: "text-embedding-3-large"},
      "text-embedding-ada-002" => %{dim: 1536, source: :openai, model: "text-embedding-ada-002"},
      "gte-large" => %{dim: 1024, source: :huggingface, model: "thenlper/gte-large"},
      "bge-large-en-v1.5" => %{dim: 1024, source: :huggingface, model: "BAAI/bge-large-en-v1.5"}
    }
  end

  @doc "Get the dimension for the configured model."
  @spec configured_dimension() :: integer()
  def configured_dimension do
    model_name = Mosaic.Config.get(:embedding_model_name, "all-MiniLM-L6-v2")
    case Map.get(models(), model_name) do
      %{dim: dim} -> dim
      nil -> 384
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec init(keyword()) :: {:ok, State.t()}
  def init(_opts) do
    model_name = Mosaic.Config.get(:embedding_model_name, "all-MiniLM-L6-v2")
    model_type = Mosaic.Config.get(:embedding_provider, "local")
    model_config = Map.get(models(), model_name, %{dim: 384, source: :huggingface, model: "sentence-transformers/all-MiniLM-L6-v2"})

    model_ref = case model_type do
      "local" ->
        try do
          create_local_serving(model_config)
        rescue
          e ->
            Logger.warning("Embedding model unavailable (network/disk): #{inspect(e)}")
            Logger.warning("Embedding service will return zero vectors — semantic search degraded")
            :unavailable
        end
      "openai" -> :openai
      "huggingface_cloud" -> :huggingface_cloud
      _ ->
        try do
          create_local_serving(model_config)
        rescue
          e ->
            Logger.warning("Embedding model unavailable: #{inspect(e)}")
            :unavailable
        end
    end

    # Update the global dimension config
    Application.put_env(:mosaic, :embedding_dim, model_config.dim)

    {:ok, %State{
      model_type: model_type,
      model_ref: model_ref,
      model_name: model_name,
      dimension: model_config.dim
    }}
  end

  defp create_local_serving(model_config) do
    model_id = model_config.model
    Logger.info("Loading embedding model: #{model_id}")
    {:ok, model_info} = Bumblebee.load_model({:hf, model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_id})
    serving = Bumblebee.Text.text_embedding(model_info, tokenizer,
      compile: [batch_size: 32, sequence_length: 256],
      defn_options: [compiler: EXLA]
    )
    %{model: serving, tokenizer: tokenizer}
  end

  @spec encode(String.t()) :: embedding()
  def encode(text) when is_binary(text) do
    case Mosaic.EmbeddingCache.get(text) do
      {:ok, embedding} -> embedding
      :miss ->
        # Route through GenServer which has the loaded model
        GenServer.call(__MODULE__, {:encode, text}, @timeout)
    end
  end

  def encode_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:encode_batch, texts}, @timeout * 2)
  end

  def handle_call({:encode, text}, _from, state) do
    try do
      [embedding] = generate_embeddings([text], state.model_type, state.model_ref)
      {:reply, embedding, state}
    rescue
      e ->
        Logger.error("Embedding failed: #{inspect(e)}")
        {:reply, List.duplicate(0.0, 384), state}
    catch
      kind, reason ->
        Logger.error("Embedding failed (#{kind}): #{inspect(reason)}")
        {:reply, List.duplicate(0.0, 384), state}
    end
  end

  def handle_call({:encode_batch, texts}, _from, state) do
    try do
      embeddings = generate_embeddings(texts, state.model_type, state.model_ref)
      Enum.zip(texts, embeddings) |> Enum.each(fn {t, e} -> Mosaic.EmbeddingCache.put(t, e) end)
      {:reply, embeddings, state}
    rescue
      e ->
        Logger.error("Batch embedding failed: #{inspect(e)}")
        {:reply, Enum.map(texts, fn _ -> zero_embedding() end), state}
    end
  end

  defp generate_embeddings(texts, _model_type, :unavailable), do: Enum.map(texts, fn _ -> zero_embedding() end)
  defp generate_embeddings(texts, _model_type, %{model: serving}) do
    Logger.info("Generating local embeddings using Bumblebee...")
    Nx.Serving.run(serving, texts) |> Enum.map(fn %{embedding: t} -> Nx.to_list(t) end)
  end

  defp generate_embeddings(texts, _model_type, :openai), do: generate_openai_embeddings(texts)
  defp generate_embeddings(texts, _model_type, :huggingface_cloud), do: generate_huggingface_embeddings(texts)

  defp generate_openai_embeddings(texts) do
    api_key = System.get_env("OPENAI_API_KEY")
    texts
    |> Enum.chunk_every(100)
    |> Enum.flat_map(fn batch ->
      resp = Req.post!("https://api.openai.com/v1/embeddings",
        json: %{input: batch, model: "text-embedding-3-large"},
        headers: [{"Authorization", "Bearer #{api_key}"}])
      resp.body["data"] |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
    end)
  rescue
    e -> Logger.error("OpenAI failed: #{inspect(e)}"); Enum.map(texts, fn _ -> List.duplicate(0.0, 1536) end)
  end

  defp generate_huggingface_embeddings(texts) do
    api_key = Mosaic.Config.get(:huggingface_api_key)
    Req.post!("https://api-inference.huggingface.co/models/sentence-transformers/all-MiniLM-L6-v2",
      json: texts, headers: [{"Authorization", "Bearer #{api_key}"}]).body
  rescue
    e -> Logger.error("HuggingFace failed: #{inspect(e)}"); Enum.map(texts, fn _ -> List.duplicate(0.0, 384) end)
  end
end

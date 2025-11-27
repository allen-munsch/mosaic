defmodule Mosaic.EmbeddingService do
  use GenServer
  require Logger

  defmodule State do
    defstruct [
      :model_type,
      :model_ref,
      :batch_queue,
      :batch_timer,
      :pending_requests,
      :batch_size,
      :batch_timeout_ms
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    model_type = Mosaic.Config.get(:embedding_model)
    batch_size = Mosaic.Config.get(:embedding_batch_size)
    batch_timeout_ms = Mosaic.Config.get(:embedding_batch_timeout_ms)

    model_ref = case model_type do
      "local" ->
        with {:ok, model_info} = Bumblebee.load_model({:hf, "bert-base-uncased"}),
             {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "bert-base-uncased"}),
             {:ok, model_info} = Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"}),
             {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"}) do
          serving = Bumblebee.Text.text_embedding(model_info, tokenizer)
          %{model: serving, tokenizer: tokenizer}
        end
      "openai" -> :openai
      "huggingface" -> :huggingface
      _ -> # Fallback to default local model
        with {:ok, model_info} = Bumblebee.load_model({:hf, "sentence-transformers/all-MiniLM-L6-v2"}),
             {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "sentence-transformers/all-MiniLM-L6-v2"}) do
          serving = Bumblebee.Text.text_embedding(model_info, tokenizer)
          %{model: serving, tokenizer: tokenizer}
        end
    end

    state = %State{
      model_type: model_type,
      model_ref: model_ref,
      batch_queue: :queue.new(),
      batch_timer: nil,
      pending_requests: %{},
      batch_size: batch_size,
      batch_timeout_ms: batch_timeout_ms
    }

    {:ok, state}
  end

  def encode(text) when is_binary(text) do
    # Check cache first
    case Mosaic.EmbeddingCache.get(text) do
      {:ok, embedding} -> embedding
      :miss ->
        GenServer.call(__MODULE__, {:encode, text}, 30_000)
    end
  end

  def encode_batch(texts) when is_list(texts) do
    GenServer.call(__MODULE__, {:encode_batch, texts}, 30_000)
  end

  def handle_call({:encode, text}, from, state) do
    # Add to batch queue
    new_queue = :queue.in({text, from}, state.batch_queue)
    queue_size = :queue.len(new_queue)

    new_state = %{state | batch_queue: new_queue}

    # Process immediately if batch is full
    if queue_size >= state.batch_size do
      process_batch(new_state)
    else
      # Schedule batch processing if not already scheduled
      timer = if state.batch_timer == nil do
        Process.send_after(self(), :process_batch, state.batch_timeout_ms)
      else
        state.batch_timer
      end

      {:noreply, %{new_state | batch_timer: timer}}
    end
  end

  def handle_call({:encode_batch, texts}, _from, state) do
    embeddings = generate_embeddings(texts, state.model_type, state.model_ref)

    # Cache results
    Enum.zip(texts, embeddings)
    |> Enum.each(fn {text, embedding} ->
      Mosaic.EmbeddingCache.put(text, embedding)
    end)

    {:reply, embeddings, state}
  end

  def handle_info(:process_batch, state) do
    new_state = process_batch(state)
    {:noreply, %{new_state | batch_timer: nil}}
  end

  defp process_batch(state) do
    if :queue.is_empty(state.batch_queue) do
      state
    else
      # Extract batch
      {batch, remaining_queue} = extract_batch(state.batch_queue, state.batch_size)

      # Generate embeddings
      texts = Enum.map(batch, fn {text, _from} -> text end)
      embeddings = generate_embeddings(texts, state.model_type, state.model_ref)

      # Cache and reply to callers
      Enum.zip(batch, embeddings)
      |> Enum.each(fn {{text, from}, embedding} ->
        Mosaic.EmbeddingCache.put(text, embedding)
        GenServer.reply(from, embedding)
      end)

      %{state | batch_queue: remaining_queue}
    end
  end

  defp extract_batch(queue, max_size) do
    extract_batch_recursive(queue, [], max_size)
  end

  defp extract_batch_recursive(queue, acc, 0) do
    {Enum.reverse(acc), queue}
  end

  defp extract_batch_recursive(queue, acc, remaining) do
    case :queue.out(queue) do
      {{:value, item}, new_queue} ->
        extract_batch_recursive(new_queue, [item | acc], remaining - 1)
      {:empty, queue} ->
        {Enum.reverse(acc), queue}
    end
  end

  defp generate_embeddings(texts, :openai, _ref) do
    generate_openai_embeddings(texts)
  end

  defp generate_embeddings(texts, "local", model_ref) do
    generate_local_embeddings(texts, model_ref)
  end

  defp generate_embeddings(texts, :huggingface, _ref) do
    generate_huggingface_embeddings(texts)
  end

  defp generate_openai_embeddings(texts) do
    api_key = System.get_env("OPENAI_API_KEY")

    with_retry(fn ->
      texts
      |> Enum.chunk_every(100)
      |> Enum.flat_map(fn batch ->
        response = Req.post!(
          "https://api.openai.com/v1/embeddings",
          json: %{
            input: batch,
            model: "text-embedding-3-large"
          },
          headers: [
            {"Authorization", "Bearer #{api_key}"},
            {"Content-Type", "application/json"}
          ]
        )

        response.body["data"]
        |> Enum.sort_by(& &1["index"])
        |> Enum.map(& &1["embedding"])
      end)
    end, 3, 100)
  rescue
    error ->
      Logger.error("OpenAI embedding generation failed after retries: #{inspect(error)}")
      Enum.map(texts, fn _ -> List.duplicate(0.0, 1536) end)
  end

  defp generate_local_embeddings(texts, %{model: serving, tokenizer: _tokenizer}) do
    Logger.info("Generating local embeddings using Bumblebee...")
    serving_output = Nx.Serving.run(serving, texts)
    
    Enum.map(serving_output, fn %{embedding: tensor_embedding} ->
      Nx.to_list(tensor_embedding)
    end)
  end

  defp generate_huggingface_embeddings(texts) do
    api_key = Mosaic.Config.get(:huggingface_api_key)

    if api_key == nil do
      Logger.error("HUGGINGFACE_API_KEY is not set. Cannot generate HuggingFace embeddings.")
      embedding_dim = Mosaic.Config.get(:embedding_dim)
      Enum.map(texts, fn _ -> List.duplicate(0.0, embedding_dim) end)
    end

    with_retry(fn ->
      response = Req.post!(
        "https://api-inference.huggingface.co/models/sentence-transformers/all-MiniLM-L6-v2",
        json: texts,
        headers: [
          {"Authorization", "Bearer #{api_key}"},
          {"Content-Type", "application/json"}
        ]
      )

      response.body
    end, 3, 100)
  rescue
    error ->
      Logger.error("HuggingFace embedding generation failed after retries: #{inspect(error)}")
      embedding_dim = Mosaic.Config.get(:embedding_dim)
      Enum.map(texts, fn _ -> List.duplicate(0.0, embedding_dim) end)
  end

  defp with_retry(fun, retries, delay) do
    _with_retry(fun, retries, delay, 0)
  end

  defp _with_retry(fun, 0, _delay, _attempt) do
    fun.()
  end

  defp _with_retry(fun, retries, delay, attempt) do
    try do
      fun.()
    rescue
      e ->
        Logger.warning("Attempt #{attempt + 1} failed, retrying in #{delay}ms. Error: #{inspect(e)}")
        :timer.sleep(delay)
        _with_retry(fun, retries - 1, delay * 2, attempt + 1)
    end
  end
end

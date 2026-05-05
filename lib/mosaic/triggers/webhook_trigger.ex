defmodule Mosaic.Triggers.WebhookTrigger do
  @moduledoc """
  Webhook triggers — fire HTTP callbacks when ingested content matches stored queries.

  Converts MosaicDB from passive storage into an active notification system.
  When new code or documents are ingested, stored triggers are checked against
  the new content. If a match is found (semantic similarity > threshold), the
  configured webhook URL is called with the matching document IDs.

  ## Usage

      # Create a trigger
      Mosaic.Triggers.WebhookTrigger.create(
        name: "new_auth_code",
        query: "authentication OR authorization",
        similarity_threshold: 0.8,
        webhook_url: "https://my-agent.example/webhook",
        on_match: :send_document_ids
      )

      # Triggers are automatically checked during ingestion via
      # the ingest pipeline hook: Mosaic.Triggers.WebhookTrigger.check_all/1

      # List active triggers
      Mosaic.Triggers.WebhookTrigger.list()

      # Test a trigger against a sample document
      Mosaic.Triggers.WebhookTrigger.test("new_auth_code", "auth flow content")
  """

  require Logger

  @type trigger :: %{
    id: String.t(),
    name: String.t(),
    query: String.t(),
    similarity_threshold: float(),
    webhook_url: String.t(),
    on_match: :send_document_ids | :send_full_text | :send_handle,
    active: boolean(),
    created_at: String.t(),
    last_fired_at: String.t() | nil,
    fire_count: integer()
  }

  @doc "Create a new trigger."
  def create(opts) do
    name = Keyword.fetch!(opts, :name)
    query = Keyword.fetch!(opts, :query)
    webhook_url = Keyword.fetch!(opts, :webhook_url)

    trigger = %{
      id: generate_id(),
      name: name,
      query: query,
      similarity_threshold: Keyword.get(opts, :similarity_threshold, 0.8),
      webhook_url: webhook_url,
      on_match: Keyword.get(opts, :on_match, :send_document_ids),
      active: Keyword.get(opts, :active, true),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      last_fired_at: nil,
      fire_count: 0
    }

    with {:ok, _} <- persist_trigger(trigger) do
      Logger.info("Trigger created: #{name} → #{webhook_url}")
      {:ok, trigger}
    end
  end

  @doc """
  Check all active triggers against newly ingested content.
  Call this from the ingest pipeline after documents are indexed.
  Returns list of triggered webhook responses.
  """
  def check_all(ingested_docs) when is_list(ingested_docs) do
    with {:ok, triggers} <- list_active() do
      if triggers == [] do
        {:ok, []}
      else
        results = Enum.flat_map(triggers, fn trigger ->
          check_trigger(trigger, ingested_docs)
        end)

        {:ok, results}
      end
    end
  end

  @doc """
  Test a trigger against a specific piece of content.
  Returns whether it matches without actually firing the webhook.
  """
  def test(trigger_name, content) when is_binary(trigger_name) and is_binary(content) do
    with {:ok, trigger} <- get_trigger(trigger_name) do
      embedding = Mosaic.EmbeddingService.encode(content)
      query_embedding = Mosaic.EmbeddingService.encode(trigger.query)

      similarity = cosine_similarity(embedding, query_embedding)
      matches = similarity >= trigger.similarity_threshold

      {:ok, %{
        trigger_name: trigger_name,
        matches: matches,
        similarity: Float.round(similarity, 4),
        threshold: trigger.similarity_threshold,
        would_fire: matches && trigger.active
      }}
    end
  end

  @doc "List all triggers."
  def list do
    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn, """
        SELECT id, name, query, similarity_threshold, webhook_url, on_match,
               active, created_at, last_fired_at, fire_count
        FROM triggers
        ORDER BY created_at DESC
      """)

      release_conn(conn)

      case result do
        {:ok, rows} ->
          triggers = Enum.map(rows, fn row -> row_to_trigger(row) end)
          {:ok, triggers}

        err -> err
      end
    end
  end

  @doc "List only active triggers."
  def list_active do
    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn, """
        SELECT id, name, query, similarity_threshold, webhook_url, on_match,
               active, created_at, last_fired_at, fire_count
        FROM triggers WHERE active = 1
        ORDER BY created_at DESC
      """)

      release_conn(conn)

      case result do
        {:ok, rows} ->
          triggers = Enum.map(rows, fn row -> row_to_trigger(row) end)
          {:ok, triggers}

        {:ok, []} -> {:ok, []}
        err -> err
      end
    end
  end

  @doc "Deactivate a trigger."
  def deactivate(trigger_name) when is_binary(trigger_name) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, "UPDATE triggers SET active = 0 WHERE name = ?", [trigger_name])
      release_conn(conn)
      :ok
    end
  end

  @doc "Delete a trigger."
  def delete(trigger_name) when is_binary(trigger_name) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, "DELETE FROM triggers WHERE name = ?", [trigger_name])
      release_conn(conn)
      :ok
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp check_trigger(trigger, docs) do
    query_embedding = Mosaic.EmbeddingService.encode(trigger.query)

    matches = Enum.filter(docs, fn doc ->
      doc_text = doc[:text] || doc[:content] || doc[:source_text] || ""
      if doc_text == "" do
        false
      else
        doc_embedding = Mosaic.EmbeddingService.encode(doc_text)
        sim = cosine_similarity(doc_embedding, query_embedding)
        sim >= trigger.similarity_threshold
      end
    end)

    if matches != [] do
      fire_webhook(trigger, matches)
      [%{trigger: trigger.name, matches: length(matches), webhook_url: trigger.webhook_url}]
    else
      []
    end
  end

  defp fire_webhook(trigger, matches) do
    payload = case trigger.on_match do
      :send_document_ids ->
        Jason.encode!(%{
          trigger: trigger.name,
          matched_ids: Enum.map(matches, & &1[:id]),
          count: length(matches)
        })

      :send_full_text ->
        Jason.encode!(%{
          trigger: trigger.name,
          matches: Enum.map(matches, fn m ->
            %{id: m[:id], text: String.slice(m[:text] || m[:content] || "", 0, 500)}
          end),
          count: length(matches)
        })

      :send_handle ->
        handle = Mosaic.HandleRegistry.store(
          "trigger_#{trigger.name}_#{System.unique_integer([:positive])}",
          matches, ttl: 3600)
        Jason.encode!(%{trigger: trigger.name, handle: handle, count: length(matches)})
    end

    Task.start(fn ->
      case Req.post(trigger.webhook_url,
             body: payload,
             headers: %{"content-type" => "application/json", "x-mosaic-trigger" => trigger.name},
             max_retries: 2,
             retry_delay: &retry_delay/1) do
        {:ok, %{status: status}} when status in 200..299 ->
          record_fire(trigger.name)

        {:ok, %{status: status}} ->
          Logger.warning("Trigger #{trigger.name} webhook returned #{status}")

        {:error, reason} ->
          Logger.error("Trigger #{trigger.name} webhook failed: #{inspect(reason)}")
      end
    end)
  end

  defp retry_delay(attempt), do: attempt * 1000

  defp record_fire(trigger_name) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn,
        "UPDATE triggers SET last_fired_at = datetime('now'), fire_count = fire_count + 1 WHERE name = ?",
        [trigger_name])
      release_conn(conn)
      :ok
    end
  end

  defp get_trigger(name) do
    with {:ok, conn} <- get_conn() do
      result = Mosaic.DB.query(conn, """
        SELECT id, name, query, similarity_threshold, webhook_url, on_match,
               active, created_at, last_fired_at, fire_count
        FROM triggers WHERE name = ?
      """, [name])

      release_conn(conn)

      case result do
        {:ok, [row | _]} -> {:ok, row_to_trigger(row)}
        {:ok, []} -> {:error, :not_found}
        err -> err
      end
    end
  end

  defp persist_trigger(trigger) do
    with {:ok, conn} <- get_conn() do
      Mosaic.DB.execute(conn, """
        INSERT OR REPLACE INTO triggers (id, name, query, similarity_threshold, webhook_url, on_match, active)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      """, [
        trigger.id, trigger.name, trigger.query, trigger.similarity_threshold,
        trigger.webhook_url, Atom.to_string(trigger.on_match),
        if(trigger.active, do: 1, else: 0)
      ])
      release_conn(conn)
      {:ok, trigger.id}
    end
  end

  defp row_to_trigger([id, name, query, threshold, url, on_match, active, created_at, last_fired, fire_count]) do
    %{
      id: id,
      name: name,
      query: query,
      similarity_threshold: threshold,
      webhook_url: url,
      on_match: String.to_atom(on_match),
      active: active == 1,
      created_at: created_at,
      last_fired_at: last_fired,
      fire_count: fire_count || 0
    }
  end

  defp cosine_similarity(v1, v2) do
    dot = Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    n1 = :math.sqrt(Enum.reduce(v1, 0.0, fn x, acc -> acc + x * x end))
    n2 = :math.sqrt(Enum.reduce(v2, 0.0, fn x, acc -> acc + x * x end))
    if n1 == 0.0 or n2 == 0.0, do: 0.0, else: dot / (n1 * n2)
  end

  defp trigger_db_path do
    Mosaic.Config.get(:trigger_db_path, Path.join(Mosaic.Config.get(:storage_path), "triggers.db"))
  end

  defp get_conn do
    path = trigger_db_path()
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, "")
    ensure_schema()
    Mosaic.ConnectionPool.checkout(path)
  end

  defp release_conn(conn) do
    Mosaic.ConnectionPool.checkin(trigger_db_path(), conn)
  end

  defp ensure_schema do
    unless Process.get(:trigger_schema_ensured) do
      Process.put(:trigger_schema_ensured, true)
      Mosaic.ConnectionPool.scoped_checkout(trigger_db_path(), fn conn ->
        Mosaic.DB.execute(conn, """
          CREATE TABLE IF NOT EXISTS triggers (
            id TEXT PRIMARY KEY,
            name TEXT UNIQUE NOT NULL,
            query TEXT NOT NULL,
            similarity_threshold REAL DEFAULT 0.8,
            webhook_url TEXT NOT NULL,
            on_match TEXT DEFAULT 'send_document_ids',
            active INTEGER DEFAULT 1,
            created_at TEXT DEFAULT (datetime('now')),
            last_fired_at TEXT,
            fire_count INTEGER DEFAULT 0
          );
        """)
        :ok
      end)
    end
  end

  defp generate_id, do: "trig_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"
end

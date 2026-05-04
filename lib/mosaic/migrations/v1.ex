defmodule Mosaic.Migrations.V1 do
  @moduledoc """
  Initial schema migration: documents, chunks, graph, handles, and vec extensions.

  This is the baseline schema that all MosaicDB shards must have.
  Applied once when a new shard is created or when migrating from pre-migration code.
  """

  @behaviour Mosaic.Migrations

  @impl true
  def up(conn) do
    # ── Legacy: documents + chunks ──────────────────────────
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        metadata JSON,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    """)

    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS chunks (
        id TEXT PRIMARY KEY,
        doc_id TEXT NOT NULL,
        parent_id TEXT,
        level TEXT NOT NULL,
        text TEXT NOT NULL,
        start_offset INTEGER NOT NULL,
        end_offset INTEGER NOT NULL,
        pagerank REAL DEFAULT 0.0,
        FOREIGN KEY (doc_id) REFERENCES documents(id) ON DELETE CASCADE
      );
    """)

    # ── Graph: nodes + edges ─────────────────────────────────
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS nodes (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL,
        language TEXT,
        file_path TEXT,
        start_line INTEGER,
        end_line INTEGER,
        source_text TEXT,
        parent_id TEXT,
        properties JSON,
        embedding BLOB,
        embedding_256 BLOB,
        embedding_128 BLOB,
        embedding_64 BLOB,
        created_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (parent_id) REFERENCES nodes(id)
      );
    """)

    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS edges (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        type TEXT NOT NULL,
        confidence TEXT DEFAULT 'EXTRACTED',
        properties JSON,
        weight REAL DEFAULT 1.0,
        FOREIGN KEY (source_id) REFERENCES nodes(id),
        FOREIGN KEY (target_id) REFERENCES nodes(id)
      );
    """)

    # ── Handles ──────────────────────────────────────────────
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS handles (
        handle_name TEXT PRIMARY KEY,
        result_type TEXT NOT NULL DEFAULT 'array',
        item_count INTEGER DEFAULT 0,
        preview TEXT,
        full_data BLOB,
        created_at TEXT DEFAULT (datetime('now')),
        ttl_seconds INTEGER DEFAULT 3600
      );
    """)

    # ── Indexes ──────────────────────────────────────────────
    indexes = [
      "CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(doc_id);",
      "CREATE INDEX IF NOT EXISTS idx_chunks_parent ON chunks(parent_id);",
      "CREATE INDEX IF NOT EXISTS idx_chunks_level ON chunks(level);",
      "CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);",
      "CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id);",
      "CREATE INDEX IF NOT EXISTS idx_nodes_file ON nodes(file_path);",
      "CREATE INDEX IF NOT EXISTS idx_nodes_name ON nodes(name);",
      "CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_id, type);",
      "CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target_id, type);",
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_edges_dedup ON edges(source_id, target_id, type);",
      "CREATE INDEX IF NOT EXISTS idx_handles_created ON handles(created_at);",
    ]
    Enum.each(indexes, &Exqlite.Sqlite3.execute(conn, &1))

    # ── Vector tables ────────────────────────────────────────
    ensure_vec_tables(conn)

    :ok
  end

  @impl true
  def down(conn) do
    tables = ["documents", "chunks", "nodes", "edges", "handles",
              "vec_chunks", "vec_nodes_64", "vec_nodes_128", "vec_nodes_256", "vec_nodes_384"]
    Enum.each(tables, fn table ->
      Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS #{table};")
    end)
    Exqlite.Sqlite3.execute(conn, "DROP TABLE IF EXISTS schema_migrations;")
    :ok
  end

  defp ensure_vec_tables(conn) do
    embedding_dim = 384
    matryoshka_levels = [64, 128, 256, embedding_dim]

    create_vec = """
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
      id TEXT PRIMARY KEY,
      embedding float[#{embedding_dim}]
    );
    """
    Exqlite.Sqlite3.execute(conn, create_vec)

    Enum.each(matryoshka_levels, fn dims ->
      table_name = "vec_nodes_#{dims}"
      create_sql = """
      CREATE VIRTUAL TABLE IF NOT EXISTS #{table_name} USING vec0(
        id TEXT PRIMARY KEY,
        embedding float[#{dims}]
      );
      """
      Exqlite.Sqlite3.execute(conn, create_sql)
    end)

    :ok
  end
end

# migrations/ — Schema Versioning

Idempotent SQLite migrations. Ensures all shard databases are at the
correct schema version regardless of when they were created.

## Modules

- `migrations.ex` — Migration runner with @callback behaviour.
  Applies migrations in order, tracks version in schema_version table.
- `migrations/v1.ex` — Initial schema: documents, chunks, vec_chunks tables.

## Isolation

- **Depends on**: `db.ex`, `storage_manager.ex`
- **Does NOT depend on**: graph, ast, document, vector, rag, auth, tenancy
- **Wraps**: storage_manager.ex (schema creation)
- **Consumed by**: storage_manager.ex (on shard creation and startup)

## Adding a Migration

```elixir
# migrations/v2.ex
defmodule Mosaic.Migrations.V2 do
  @behaviour Mosaic.Migrations

  @impl true
  def up(conn) do
    Mosaic.DB.execute(conn, "ALTER TABLE nodes ADD COLUMN tags JSON")
  end

  @impl true
  def down(conn) do
    # SQLite doesn't support DROP COLUMN easily; document manual rollback
    :ok
  end
end

# Then add to migrations.ex @migrations list:
@migrations [Mosaic.Migrations.V1, Mosaic.Migrations.V2]
```

## Rules

- Migrations must be IDEMPOTENT (use IF NOT EXISTS, IF EXISTS)
- Never delete data in a migration (only add columns/tables)
- Version is stored in `schema_version` table per shard

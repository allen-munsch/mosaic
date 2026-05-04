# embedding/ — Matryoshka Embedding Utilities

Multi-level embedding truncation and binary encoding. Matryoshka embeddings
are vectors where the first K dimensions form a valid lower-resolution
embedding — enabling cascaded search.

## Modules

- `matryoshka.ex` — Truncate to any dimension, truncate_binary for float32 blobs,
  encode_levels for bulk processing, vec table name resolution, cascade factors

## Isolation

- **Depends on**: `config.ex`, `embedding_service.ex`
- **Does NOT depend on**: any other domain
- **Consumed by**: vector/cascaded_search.ex, graph/writer.ex (embedding storage)

## Making Changes

- New embedding model: update `embedding_service.ex`, not this module
- New dimension level: update `config.ex` matryoshka_levels
- This module is PURE MATH — no I/O, no side effects

# rag/ — RAG Pipeline

End-to-end retrieval-augmented generation: search → retrieve chunks →
assemble context. Supports vector, keyword, and hybrid retrieval.
Extreme compression via handle stubs.

## Modules

- `pipeline.ex` — retrieve/2 (vector → keyword fallback → context assembly),
  retrieve_compressed/2 (handle stubs, 97% savings), retrieve_hybrid/2
  (vector + keyword combined)

## Isolation

- **Depends on**: `vector/cascaded_search.ex`, `handle_registry.ex`, `federated_query.ex`
- **Does NOT depend on**: graph, ast, document, auth, tenancy
- **Consumed by**: mcp/tools.ex, bin/mosaic (mosaic rag)
- **Platform layers**: none needed — RAG is read-only retrieval

## Making Changes

- New retrieval strategy: add function to pipeline.ex
- New ranking/sorting: add to pipeline.ex
- Never import from document/ or graph/ — rag consumes vectors + handles, not raw docs

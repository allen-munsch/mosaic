# vector/ — Matryoshka Cascaded Vector Search

Progressive refinement across dimension levels (64d → 128d → 256d → 384d).
Queries vec_nodes_* virtual tables via sqlite-vec for 10-50x speedup.

## Modules

- `cascaded_search.ex` — 4-stage progressive refinement pipeline. Configurable
  cascade factors per level, type/file filters, candidate-ID-restricted searches.

## Isolation

- **Depends on**: `embedding/matryoshka.ex`, `federated_query.ex`
- **Does NOT depend on**: graph, ast, document, rag, auth, tenancy
- **Consumed by**: rag/pipeline.ex (retrieval), api.ex (search endpoint), mcp/tools.ex
- **Platform layers**: none needed

## Making Changes

- New dimension level: update `config.ex` matryoshka_levels
- New search strategy: add function to cascaded_search.ex
- Schema: vec tables created in `storage_manager.ex`
- Never import from rag/ or document/ — vector search is generic

# ast/ — Code Parsing & Symbol Extraction

Parses source code into typed symbols (nodes) and relationships (edges).
Two backends: tree-sitter via ast-grep (rich) and built-in regex (zero-dependency).

## Modules

- `parser.ex` — Tree-sitter bridge via ast-grep CLI, language detection for 14+ extensions
- `builtin_parser.ex` — Pure-regex Elixir/Python symbol extractor (no external deps)
- `symbol_extractor.ex` — Walk tree-sitter CST to extract typed nodes with
  per-language mappings (Elixir, Python, Rust, Go, JS/TS, Ruby)
- `relationship_extractor.ex` — Derive edges from AST: calls, contains, imports,
  references with EXTRACTED/INFERRED/AMBIGUOUS confidence
- `ingestor.ex` — Orchestrate file/dir/repo ingestion with parallel Task.async_stream

## Isolation

- **Depends on**: `graph/writer.ex` (writes nodes + edges), `embedding_service.ex` (optional)
- **Does NOT depend on**: graph/traversal, document, vector, rag, auth, tenancy
- **Consumed by**: mcp/tools.ex (mosaic_load), scripts/index_codebase.exs, bin/mosaic
- **Platform layers**: none needed — ast operates on source files, not tenant data

## Making Changes

- New language support: add mappings to `builtin_parser.ex` or `symbol_extractor.ex`
- New edge types: add to `relationship_extractor.ex`
- Schema changes: nodes/edges schema is in `storage_manager.ex`
- Never import from graph/traversal.ex — ast PRODUCES graph data, doesn't consume it

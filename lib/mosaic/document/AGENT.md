# document/ — Universal Document Ingestion

Reads PDF, DOCX, MD, TXT, HTML. Chunks with 5 strategies. Ingests into
MosaicDB shards for RAG retrieval.

## Modules

- `reader.ex` — Multi-format reader: pdftotext (PDF), unzip+XML (DOCX),
  HTML tag stripping, plain text. URL fetching via Req.
- `chunker.ex` — 5 chunking strategies: paragraph, sentence, fixed-size,
  markdown (heading-aware), sliding window with overlap. Preserves provenance.
- `ingestor.ex` — Orchestrate: single file, directory, S3 bucket prefix,
  URL. Parallel Task.async_stream for throughput.

## Isolation

- **Depends on**: `graph/writer.ex` (writes chunk nodes), `embedding_service.ex` (optional)
- **Does NOT depend on**: graph/traversal, ast, vector, rag, auth, tenancy
- **Consumed by**: rag/pipeline.ex (retrieval), mcp/tools.ex, bin/mosaic (mosaic docs)
- **Platform layers**: none needed — documents are source data

## Making Changes

- New format support: add to `reader.ex`
- New chunking strategy: add to `chunker.ex`
- New ingestion source (GCS, Azure Blob): add to `ingestor.ex`
- Never import from rag/ — document PRODUCES chunks, rag CONSUMES them

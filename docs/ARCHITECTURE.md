# Semantic Fabric - Architecture Diagrams

## System Overview

```
                                    ┌─────────────────────────────────────┐
                                    │         Internet / Users            │
                                    └──────────────┬──────────────────────┘
                                                   │
                                    ┌──────────────▼──────────────────────┐
                                    │      Nginx Load Balancer            │
                                    │  - SSL Termination                  │
                                    │  - Rate Limiting                    │
                                    │  - Health Checks                    │
                                    └──────┬──────────────┬───────────────┘
                                           │              │
                    ┌──────────────────────┴──────┐       │
                    │                             │       │
         ┌──────────▼──────────┐       ┌──────────▼───────▼────┐
         │   Coordinator Node   │◄─────►│   Worker Pool        │
         │                      │       │  (Worker-1, Worker-2) │
         │  ┌────────────────┐ │       │                       │
         │  │ Shard Router   │ │       │  ┌─────────────────┐ │
         │  │  - Bloom       │ │       │  │ Query Executor  │ │
         │  │  - Centroids   │ │       │  │  - Parallel     │ │
         │  │  - Cache       │ │       │  │  - Circuit Break│ │
         │  └────────────────┘ │       │  └─────────────────┘ │
         │                      │       │                       │
         │  ┌────────────────┐ │       │  ┌─────────────────┐ │
         │  │ Embedding Svc  │◄┼───────┼─►│ Embeddings      │ │
         │  │  - Batching    │ │       │  │  - Cache        │ │
         │  │  - Caching     │ │       │  └─────────────────┘ │
         │  └────────────────┘ │       │                       │
         │                      │       │  ┌─────────────────┐ │
         │  ┌────────────────┐ │       │  │ Shard Storage   │ │
         │  │ PageRank Comp  │ │       │  │  (SQLite DBs)   │ │
         │  │  - Distributed │ │       │  └─────────────────┘ │
         │  └────────────────┘ │       │                       │
         └──────────┬───────────┘       └───────────┬───────────┘
                    │                               │
                    │    ┌─────────────────────────┴────────┐
                    │    │                                  │
         ┌──────────▼────▼──────┐            ┌──────────────▼─────────┐
         │  Redis (Optional)     │            │   Persistent Storage   │
         │  - Distributed Cache  │            │   - Coordinator Volume │
         │  - Session Store      │            │   - Worker Volumes     │
         └───────────────────────┘            └────────────────────────┘
                    │
         ┌──────────▼────────────┐
         │   Monitoring Stack    │
         │  - Prometheus         │
         │  - Grafana            │
         │  - Health Checks      │
         └───────────────────────┘
```

## Query Flow Diagram

```
┌─────────┐
│  Client │
└────┬────┘
     │ 1. POST /api/search
     │    {"query": "machine learning"}
     ▼
┌─────────────────┐
│  Nginx LB       │
│  Rate Limit ✓   │
└────┬────────────┘
     │ 2. Route to healthy node
     ▼
┌──────────────────────────────────────────────────────────────┐
│  Coordinator Node                                             │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ Query Engine                                             ││
│  │  3. Receive query: "machine learning"                   ││
│  └─────────────────────┬───────────────────────────────────┘│
│                        │                                     │
│  ┌─────────────────────▼───────────────────────────────────┐│
│  │ Embedding Service                                        ││
│  │  4. Generate embedding vector                            ││
│  │     Check cache → [HIT!] Return cached embedding        ││
│  │     or                                                   ││
│  │     Generate new → [1024-dim vector]                    ││
│  └─────────────────────┬───────────────────────────────────┘│
│                        │                                     │
│  ┌─────────────────────▼───────────────────────────────────┐│
│  │ Shard Router                                             ││
│  │  5. Find similar shards                                  ││
│  │     a) Check bloom filters (if keywords)                ││
│  │     b) Compute cosine similarity with centroids         ││
│  │     c) Return top 50 shards (sorted by similarity)      ││
│  │        [shard_001: 0.92, shard_042: 0.89, ...]         ││
│  └─────────────────────┬───────────────────────────────────┘│
└────────────────────────┼───────────────────────────────────-─┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
┌───────▼──────────┐            ┌─────────▼────────┐
│   Worker 1       │            │   Worker 2       │
│                  │            │                  │
│  ┌────────────┐ │            │  ┌────────────┐ │
│  │Circuit     │ │            │  │Circuit     │ │
│  │Breaker ✓   │ │            │  │Breaker ✓   │ │
│  └──────┬─────┘ │            │  └──────┬─────┘ │
│         │       │            │         │       │
│  6. Parallel    │            │  6. Parallel    │
│     Search      │            │     Search      │
│         │       │            │         │       │
│  ┌──────▼──────────────┐    │  ┌──────▼──────────────┐
│  │ Shard Query         │    │  │ Shard Query         │
│  │  FOR EACH shard:    │    │  │  FOR EACH shard:    │
│  │   - Open (pooled)   │    │  │   - Open (pooled)   │
│  │   - Semantic search │    │  │   - Semantic search │
│  │   - Apply PageRank  │    │  │   - Apply PageRank  │
│  │   - Return top 10   │    │  │   - Return top 10   │
│  └──────┬──────────────┘    │  └──────┬──────────────┘
│         │                   │         │                │
│  Results: 240 docs          │  Results: 260 docs       │
└─────────┬───────────────────┘─────────┬────────────────┘
          │                             │
          └──────────────┬──────────────┘
                         │
                         │ 7. Merge & Rerank
                         ▼
        ┌────────────────────────────────────────┐
        │  Coordinator Node                      │
        │  ┌──────────────────────────────────┐ │
        │  │ Result Merger                     │ │
        │  │  - Combine 500 results            │ │
        │  │  - Deduplicate                    │ │
        │  │  - Hybrid rerank:                 │ │
        │  │    score = 0.6*pagerank +         │ │
        │  │            0.4*semantic_sim       │ │
        │  │  - Sort by score DESC             │ │
        │  │  - Take top 20                    │ │
        │  └──────────────┬───────────────────┘ │
        └─────────────────┼─────────────────────┘
                          │
                          │ 8. Return results
                          ▼
                    ┌───────────┐
                    │  Client   │
                    │  Response │
                    │  [20 docs]│
                    └───────────┘

Total Time: ~150ms
- Embedding: 10ms (cache hit) or 80ms (cache miss)
- Routing: 5ms
- Parallel search: 100ms
- Merge & rerank: 35ms
```

## Data Flow - Document Indexing

```
┌─────────────┐
│  Web Crawler│
│  or API     │
└──────┬──────┘
       │ 1. New documents batch (1000 docs)
       ▼
┌────────────────────────────────────────────────┐
│  Crawler Pipeline (GenStage)                   │
│  ┌──────────────────────────────────────────┐ │
│  │  URL Frontier                             │ │
│  │   - Priority queue                        │ │
│  │   - Rate limiting                         │ │
│  └──────────┬───────────────────────────────┘ │
│             │                                  │
│  ┌──────────▼───────────────────────────────┐ │
│  │  Crawler Workers (parallel)              │ │
│  │   - Fetch HTML                            │ │
│  │   - Extract text                          │ │
│  │   - Parse links                           │ │
│  │   - Calculate initial PageRank            │ │
│  └──────────┬───────────────────────────────┘ │
└─────────────┼────────────────────────────────-─┘
              │
              │ 2. Processed documents
              ▼
┌───────────────────────────────────────────────────┐
│  Embedding Service                                │
│  ┌─────────────────────────────────────────────┐ │
│  │  Batch Queue (accumulate until full)        │ │
│  │   - Doc 1: "Introduction to ML..."          │ │
│  │   - Doc 2: "Neural networks are..."         │ │
│  │   - ...                                      │ │
│  │   - Doc 32: "Deep learning requires..."     │ │
│  └─────────────┬───────────────────────────────┘ │
│                │                                  │
│  ┌─────────────▼───────────────────────────────┐│
│  │  Generate Embeddings (batch=32)             ││
│  │   → OpenAI API or Local Model               ││
│  │   → [1024-dim vectors] × 32                 ││
│  └─────────────┬───────────────────────────────┘│
└────────────────┼──────────────────────────────-──┘
                 │
                 │ 3. Documents + Embeddings
                 ▼
┌──────────────────────────────────────────────────────┐
│  Shard Manager                                       │
│  ┌────────────────────────────────────────────────┐ │
│  │  Buffer: 9,847 docs (target: 10,000)           │ │
│  │  New: 1,000 docs → Buffer: 10,847 docs         │ │
│  │  TRIGGER: Create new shard                     │ │
│  └────────────────┬───────────────────────────────┘ │
│                   │                                  │
│  ┌────────────────▼───────────────────────────────┐│
│  │  Shard Creation (atomic)                       ││
│  │  1. Create temp SQLite: /tmp/shard_xyz.db     ││
│  │  2. Initialize schema + VSS extension         ││
│  │  3. Insert 10,000 documents + vectors         ││
│  │  4. Calculate centroid vector                 ││
│  │  5. Build bloom filter (keywords)             ││
│  │  6. Move to: /data/shards/A7/3F/21/shard.db  ││
│  │  7. Mark immutable (read-only)                ││
│  └────────────────┬───────────────────────────────┘│
└───────────────────┼──────────────────────────────-──┘
                    │
                    │ 4. Register shard
                    ▼
┌──────────────────────────────────────────────────────┐
│  Shard Router                                        │
│  ┌────────────────────────────────────────────────┐ │
│  │  Routing Index (SQLite)                        │ │
│  │  INSERT:                                        │ │
│  │   - shard_id: "A73F21..."                      │ │
│  │   - path: "/data/shards/A7/3F/21/shard.db"    │ │
│  │   - centroid: [0.23, 0.45, ..., 0.12]         │ │
│  │   - doc_count: 10,000                          │ │
│  │   - bloom_filter: <binary>                     │ │
│  │   - status: 'active'                           │ │
│  └────────────────────────────────────────────────┘ │
│                                                      │
│  ┌────────────────────────────────────────────────┐ │
│  │  In-Memory Cache (LRU)                         │ │
│  │  UPDATE:                                        │ │
│  │   - Add shard to hot cache                     │ │
│  │   - Evict least recently used if full          │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘

                    5. Ready for queries!
```

## PageRank Computation Flow

```
┌─────────────────────────┐
│  PageRank Scheduler     │
│  (runs every 24 hours)  │
└────────┬────────────────┘
         │
         │ 1. Trigger computation
         ▼
┌─────────────────────────────────────────────────────┐
│  PageRank Computer                                  │
│  ┌───────────────────────────────────────────────┐ │
│  │  Phase 1: Build Link Graph                    │ │
│  │  FOR EACH shard:                               │ │
│  │    - Read metadata.links                       │ │
│  │    - Extract URL → [outlinks]                  │ │
│  │  Result: Graph = {                             │ │
│  │    "url1" → ["url2", "url3"],                  │ │
│  │    "url2" → ["url1", "url4"],                  │ │
│  │    ...                                          │ │
│  │  }                                              │ │
│  └───────────────┬───────────────────────────────┘ │
│                  │                                  │
│  ┌───────────────▼───────────────────────────────┐│
│  │  Phase 2: Distributed Computation (Flow)     ││
│  │  Initialize: pagerank[url] = 1.0 for all     ││
│  │  FOR iteration in 1..10:                      ││
│  │    Parallel.map(urls, fn url ->               ││
│  │      rank = 0.15 + 0.85 * (                   ││
│  │        sum of (inlink_rank / outlink_count)   ││
│  │      )                                         ││
│  │    end)                                        ││
│  │  Result: pagerank scores                      ││
│  └───────────────┬───────────────────────────────┘│
└──────────────────┼──────────────────────────────-──┘
                   │
                   │ 3. Update shards
                   ▼
┌──────────────────────────────────────────────────────┐
│  Shard Updater                                       │
│  ┌────────────────────────────────────────────────┐ │
│  │  FOR EACH shard:                                │ │
│  │    1. Copy to temp location (COW)              │ │
│  │    2. UPDATE documents                          │ │
│  │       SET pagerank = ?                          │ │
│  │       WHERE url = ?                             │ │
│  │    3. Atomically replace original               │ │
│  │    4. Update timestamp                          │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘

    4. Shards now have updated PageRank scores
```

## Shard Structure

```
Shard File: /data/shards/A7/3F/21/shard.db
┌─────────────────────────────────────────────────┐
│  SQLite Database (Immutable, Read-Only)         │
│                                                  │
│  ┌────────────────────────────────────────────┐│
│  │ documents Table                             ││
│  │ ┌──────┬─────┬───────┬─────────┬─────────┐││
│  │ │ id   │ url │ title │ content │ vector  │││
│  │ ├──────┼─────┼───────┼─────────┼─────────┤││
│  │ │ 001  │ ... │ ...   │ ...     │ <blob>  │││
│  │ │ 002  │ ... │ ...   │ ...     │ <blob>  │││
│  │ │ ...  │ ... │ ...   │ ...     │ ...     │││
│  │ │ 9999 │ ... │ ...   │ ...     │ <blob>  │││
│  │ └──────┴─────┴───────┴─────────┴─────────┘││
│  │                                             ││
│  │ Additional Columns:                         ││
│  │  - pagerank REAL (0.0 - 100.0)             ││
│  │  - metadata JSON (author, date, etc)       ││
│  │  - created_at DATETIME                      ││
│  └────────────────────────────────────────────┘│
│                                                  │
│  ┌────────────────────────────────────────────┐│
│  │ vss_documents (Virtual Table)               ││
│  │  - Vector index for fast similarity search ││
│  │  - Uses sqlite-vec extension                ││
│  │  - Supports vss_search() and vss_distance() ││
│  └────────────────────────────────────────────┘│
│                                                  │
│  File Size: ~50-100MB (compressed)              │
│  Read Performance: 1-2ms per query              │
│  Immutable: Can be cached, replicated           │
└─────────────────────────────────────────────────┘
```

## Scaling Strategy

```
                    Growth Path
                    
Stage 1: Single Node (Up to 1M docs)
┌─────────────────┐
│  Coordinator    │  4 CPU, 8GB RAM
│  (All-in-One)   │  100 shards
└─────────────────┘
      Capacity: 1M documents
      QPS: ~50 queries/sec

                    │
                    │ Add Workers
                    ▼
                    
Stage 2: Small Cluster (Up to 10M docs)
┌─────────────┐     ┌─────────────┐
│ Coordinator │◄───►│  Worker 1   │  8 CPU, 16GB RAM
│             │     │  500 shards │
└─────────────┘     └─────────────┘
                    ┌─────────────┐
                    │  Worker 2   │  8 CPU, 16GB RAM
                    │  500 shards │
                    └─────────────┘
      Capacity: 10M documents
      QPS: ~200 queries/sec
      
                    │
                    │ Scale Out
                    ▼
                    
Stage 3: Medium Cluster (Up to 100M docs)
┌─────────────┐     ┌──────────────────────────┐
│ Coordinator │◄───►│  Worker Pool (10 nodes)  │
│   (2 nodes) │     │  10,000 shards total     │
└─────────────┘     └──────────────────────────┘
      Capacity: 100M documents
      QPS: ~1,000 queries/sec
      
                    │
                    │ Multi-Region
                    ▼
                    
Stage 4: Large Cluster (Up to 1B+ docs)
┌─────────────┐     ┌──────────────────────────┐
│Coordinator  │     │   US Region (50 nodes)   │
│  Cluster    │◄───►│   50,000 shards          │
│ (US/EU/AP)  │     └──────────────────────────┘
└─────────────┘     ┌──────────────────────────┐
                    │   EU Region (50 nodes)   │
                    │   50,000 shards          │
                    └──────────────────────────┘
      Capacity: 1B+ documents
      QPS: ~10,000 queries/sec
      Geographic distribution
```

## Failure Recovery Scenarios

```
Scenario 1: Worker Node Failure
───────────────────────────────────
Time 0:   [Coordinator] ─── [Worker-1] ✓ ─── [Worker-2] ✓
                                 ↓
Time 1:   [Coordinator] ─── [Worker-1] ✗ ─── [Worker-2] ✓
          Detection: Health check fails
          
Time 2:   [Coordinator] ─── [Worker-1] ✗ ─── [Worker-2] ✓
          Action: Circuit breaker opens for Worker-1
                  Route queries only to Worker-2
          
Time 3:   [Coordinator] ─── [Worker-1] ✓ ─── [Worker-2] ✓
          Recovery: Worker-1 restarts
                    Coordinator detects healthy status
                    Circuit breaker closes
                    Traffic resumes


Scenario 2: Coordinator Failure
────────────────────────────────
Time 0:   [Coordinator-1] ✓ ── Primary
          [Coordinator-2] ✓ ── Standby
          
Time 1:   [Coordinator-1] ✗
          [Coordinator-2] ✓ ── Promotes to Primary
          Action: Standby detects primary failure
                  Takes over routing responsibilities
                  
Time 2:   [Coordinator-1] ✓ ── Rejoins as Standby
          [Coordinator-2] ✓ ── Remains Primary


Scenario 3: Shard Corruption
─────────────────────────────
Time 0:   Shard A73F21 becomes corrupted
          
Time 1:   Worker attempts to read → Error
          Circuit breaker: Mark shard unhealthy
          
Time 2:   Queries skip corrupted shard
          Return partial results
          
Time 3:   Admin restores from backup
          OR
          Rebuild shard from source documents
          
Time 4:   Shard marked healthy
          Resumes serving queries
```

---

## Performance Benchmarks (Goals)

### Query Latency Distribution
```
  0-50ms    ████████████████████████ 60%
 50-100ms   ████████████ 30%
100-200ms   ████ 8%
200-500ms   █ 2%
   >500ms   (outliers)
```

### Cache Hit Rates
```
Embedding Cache:  ████████████████ 85%
Routing Cache:    ███████████████ 78%
Connection Pool:  ████████████████████ 95%
```

### Resource Utilization (Under Load)
```
CPU:      ████████░░░░░░░░ 45%
Memory:   ██████████████░░ 75%
Disk I/O: ████░░░░░░░░░░░░ 20%
Network:  ██████░░░░░░░░░░ 30%
```


## Vector Search Landscape Comparison

| Aspect | **PostgreSQL + pgvector** | **FAISS** | **Qdrant** | **Pinecone** | **Weaviate** | **MosaicDB** |
|--------|---------------------------|-----------|------------|--------------|--------------|----------------------|
| **Type** | RDBMS + extension | Library | Vector DB | Managed service | Vector DB | Distributed search engine |
| **Architecture** | Single node (+ replicas) | In-memory indexes | Rust-based, distributed | Fully managed cloud | Go-based, modular | SQLite shards + Elixir coordination |
| **Primary Language** | C / SQL | C++ / Python | Rust | N/A (API only) | Go | Elixir |
| **Vector Index Types** | IVFFlat, HNSW | IVF, HNSW, PQ, flat | HNSW | Proprietary | HNSW | sqlite-vec (Faiss-based) |
| **Max Vectors (practical)** | ~10M | 1B+ (with sharding) | 100M+ | "Unlimited" (paid) | 100M+ | Goal Unlimited |
| **Hybrid Search** | Full SQL + vectors | No (vectors only) | Filters + vectors | Metadata filters | BM25 + vectors | SQL + vectors + PageRank |
| **ACID Transactions** | Full | None | Limited | None | None | Per-shard only |
| **Hosting Model** | Self-host or managed | Library (embed in app) | Self-host or cloud | Cloud only | Self-host or cloud | Self-host |
| **Operational Complexity** | Low (familiar) | Very low (it's a library) | Medium | None (managed) | Medium | Low |
| **Cost at Scale** | $$ (compute) | $ (just RAM) | $$ | $$$$ | $$ | $ (SQLite is cheap) |
| **Latency (p50)** | 5-50ms | <1-10ms | 5-30ms | 10-50ms | 10-50ms | 50-200ms (estimated) |
| **Learning Curve** | Low | Medium | Medium | Very low | Medium | Low |
| **Community/Ecosystem** | Massive | Large | Growing | Moderate | Growing | Tiny |

---

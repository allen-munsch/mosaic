# index/ — Pluggable Vector Index Strategies

6 index strategies implementing a common @behaviour. Swappable at runtime.
Each strategy has its own state, persistence, and optimization path.

## Modules

- `strategy.ex` — Behaviour: init, index_document, find_candidates, delete_document,
  get_stats, serialize, deserialize, optimize
- `strategy/hnsw.ex` — Hierarchical Navigable Small World graphs (logarithmic search)
- `strategy/ivf.ex` — Inverted File Index with clustering
- `strategy/pq.ex` — Product Quantization for compressed vectors
- `strategy/binary.ex` — Binary embeddings with XOR + POPCNT
- `strategy/centroid.ex` — Shard-level centroid routing
- `strategy/quantized.ex` — Scalar quantization with hierarchical cells
- `strategy_factory.ex` — Create strategies from config atoms
- `strategy_server.ex` — GenServer wrapper for stateful strategy management
- `supervisor.ex` — DynamicSupervisor for strategy processes
- `router.ex` — Route queries to active strategy

## Isolation

- **Depends on**: `db.ex`, `config.ex`, `vector_math.ex`
- **Does NOT depend on**: graph, ast, document, vector, rag, auth, tenancy
- **Consumed by**: query_engine.ex (index selection), application.ex (supervision)

## Adding a New Strategy

1. Create `index/strategy/new_strategy.ex`
2. Implement `@behaviour Mosaic.Index.Strategy`
3. Add to `strategy_factory.ex` and `application.ex` index_strategy_child_spec

# graph/ — Property Graph Database

Stores nodes and edges in SQLite shards. Provides recursive CTE traversals for
code graph exploration. This is the core data model for code analysis.

## Modules

- `traversal.ex` — Recursive CTE graph traversals (callers, callees, ancestors,
  descendants, implementations, neighborhood, god_nodes, bridge_nodes, dependents)
- `writer.ex` — Transactional bulk write of nodes + edges with matryoshka
  embedding levels (64/128/256/384d vec tables)
- `communities.ex` — SQL-based community detection (package-boundary modularity)
- `report.ex` — Comprehensive graph analysis: god nodes, bridge nodes,
  surprising connections, suggested questions
- `federated_traversal.ex` — Cross-shard fan-out for recursive CTEs
- `shard_strategy.ex` — Package-boundary shard routing with consistent hashing

## Isolation

- **Depends on**: `db.ex`, `config.ex`, `connection_pool.ex`, `federated_query.ex`
- **Does NOT depend on**: ast, document, vector, rag, auth, tenancy
- **Consumed by**: api.ex, mcp/tools.ex, scripts/
- **Platform layers**: tenancy wraps writer.ex with path prefixing

## Making Changes

- New traversal types: add to `traversal.ex`
- New graph algorithms: add to `communities.ex` or `report.ex`
- Schema changes: update `storage_manager.ex` create_graph_schema/1
- Never import from ast/ or document/ — graph is generic, not code-specific

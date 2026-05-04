# consensus/ — Distributed Consensus (Raft)

Uses `:ra` (Team RabbitMQ) for strongly consistent metadata coordination
across cluster nodes. Replaces the Hobbes VSR simulator with production-grade
Raft consensus.

## Modules

- `cluster.ex` — Raft cluster management: server lifecycle, leader election,
  log replication, state machine for shard topology and handle registry.

## Isolation

- **Depends on**: `:ra` (hex package), `config.ex`
- **Does NOT depend on**: graph, ast, document, vector, rag, reify
- **Wraps**: shard_router.ex, handle_registry.ex (consistent state replication)
- **Consumed by**: application.ex (cluster supervision), shard_router.ex

## Making Changes

- New replicated state: add to cluster.ex state machine
- Cluster topology changes: update cluster membership in config
- Never add business logic to consensus — it only replicates state

## Architecture

```
Node-1 (leader)     Node-2 (follower)    Node-3 (follower)
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│ :ra_server     │──│ :ra_server     │──│ :ra_server     │
│ (leader)       │  │ (follower)     │  │ (follower)     │
│ shard_topo v5  │  │ shard_topo v5  │  │ shard_topo v5  │
│ handles v3     │  │ handles v3     │  │ handles v3     │
└────────────────┘  └────────────────┘  └────────────────┘
```

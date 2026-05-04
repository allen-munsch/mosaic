# tenancy/ — Multi-Tenant Isolation

Routes all storage operations through tenant-scoped paths. Works with
auth layer to enforce per-tenant access controls.

## Modules

- `isolator.ex` — Tenant-scoped storage paths, data isolation boundaries,
  access control enforcement. All I/O goes through this module when
  multi-tenancy is enabled.

## Isolation

- **Depends on**: `auth/` (scope verification), `config.ex`, `storage_manager.ex`
- **Does NOT depend on**: graph, ast, document, vector, rag, reify
- **Wraps**: storage_manager.ex (path prefixing), graph/writer.ex (tenant-aware shard routing)
- **Consumed by**: application.ex (middleware), api.ex (pipeline)

## Tenant Storage Layout

```
/shards/
├── tenant_abc123/          # Tenant A
│   ├── codebase_001.db
│   ├── docs_2024.db
│   └── handles.db
├── tenant_def456/          # Tenant B
│   ├── knowledge_base.db
│   └── handles.db
└── _system/                # Internal (auth, billing, config)
    ├── auth.db
    └── usage.db
```

## Making Changes

- New tenant-scoped resource: add path prefixing to isolator.ex
- Cross-tenant access: NEVER — tenancy is strict isolation
- Default tenant: when tenancy is disabled, all data in /shards/ root

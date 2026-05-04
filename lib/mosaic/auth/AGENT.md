# auth/ — Authentication & Authorization

JWT tokens, API key management, and Plug middleware for request authentication.
Stores auth data in a dedicated SQLite database separate from content shards.

## Modules

- `jwt.ex` — JWT generation and verification (HS256). Scope-based authorization.
- `api_key.ex` — API key management: create, validate, revoke. bcrypt hashing.
  Keys stored in SQLite auth database with scope-based permissions.
- `plug.ex` — Plug middleware for Bearer JWT and X-API-Key authentication.
  Adds :auth_claims to conn.assigns. Returns 401 on failure.

## Isolation

- **Depends on**: `db.ex`, `config.ex`, `connection_pool.ex`
- **Does NOT depend on**: graph, ast, document, vector, rag, reify, consensus
- **Wraps**: `api.ex` (as a Plug in the pipeline)
- **Consumed by**: api.ex (pipeline), tenancy/isolator.ex (scope verification)

## Making Changes

- New auth method (OAuth, SAML): add module, integrate in plug.ex
- New permission scope: add to jwt.ex scope list
- Schema: auth tables in dedicated auth.db, not in content shards
- Never add domain logic to auth modules — auth only checks, doesn't process

## Auth Database Schema

```
auth.db:
  api_keys (id, key_hash, tenant_id, scopes, created_at, revoked_at)
  sessions (id, user_id, tenant_id, token_hash, expires_at)
```

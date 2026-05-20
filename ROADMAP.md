# MosaicDB — Production Roadmap

## Monetization Strategy

**Core: Open source (MIT).** Developers self-host for free, forever.

**Revenue: Operational complexity.** Companies pay to not manage it themselves:
- Managed cloud (mosaicdb.cloud) — per-query, per-GB, per-tenant
- Enterprise license — SSO, audit, SLA, dedicated support
- Infrastructure packs — Helm charts, Terraform, ArgoCD, monitoring dashboards

The open source is the moat. The operational burden is the product.

---

## Phase 9: Python & JavaScript SDKs

**Goal:** `pip install mosaicdb` / `npm install mosaicdb` — 90% of developers never touch Elixir.

### 9.1 Python SDK (`mosaicdb` package)

```python
from mosaicdb import MosaicClient

client = MosaicClient("http://localhost:4040")

# --- Ingestion ---
client.ingest_code("./src")                    # AST parse → graph
client.ingest_docs("./kb")                     # PDF/DOCX/MD → chunks
client.ingest_s3("my-bucket", "articles/")     # S3 → chunks

# --- Search ---
client.search("error handling in auth")        # vector
client.search("neural nets",
    where="category = 'ml' AND rating >= 4")   # hybrid vector + SQL
client.search_sql("SELECT category, COUNT(*) FROM docs GROUP BY 1")

# --- Graph ---
client.traverse("my_func", relation="callers", depth=2)
client.graph_report()                          # god nodes, communities

# --- RAG ---
chunks = client.rag("auth flow", top_k=5)      # returns chunks + context
```

**Files:**
```
sdks/python/
├── pyproject.toml
├── mosaicdb/
│   ├── __init__.py
│   ├── client.py          # MosaicClient class (HTTP + MCP modes)
│   ├── search.py          # Search builders
│   ├── ingest.py          # File/dir/S3 ingestion
│   ├── graph.py           # Graph traversal wrappers
│   ├── rag.py             # RAG pipeline client
│   └── types.py           # TypedDicts for responses
├── tests/
└── README.md
```

**Effort:** 2 weeks

### 9.2 JavaScript/TypeScript SDK (`mosaicdb` package)

```typescript
import { MosaicClient } from "mosaicdb";

const client = new MosaicClient("http://localhost:4040");
const results = await client.search("error handling", { limit: 10 });
```

**Files:**
```
sdks/js/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts
│   ├── client.ts
│   ├── search.ts
│   ├── ingest.ts
│   ├── graph.ts
│   └── types.ts
├── tests/
└── README.md
```

**Effort:** 1 week

---

## Phase 10: Docker + One-Command Deploy

**Goal:** `docker run mosaicdb` — full stack running in 30 seconds.

### 10.1 Production Dockerfile

```dockerfile
# Multi-stage: build Elixir release, then slim runtime
FROM hexpm/elixir:1.17-erlang-27-debian AS build
# ... compile release with MIX_ENV=prod

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libstdc++6 poppler-utils
COPY --from=build /app/_build/prod/rel/mosaic /app
EXPOSE 4040
ENTRYPOINT ["/app/bin/mosaic"]
CMD ["start"]
```

### 10.2 docker-compose.yml

```yaml
services:
  mosaic:
    image: mosaicdb:latest
    ports: ["4040:4040"]
    volumes:
      - ./shards:/var/lib/mosaic/shards
      - ./config:/etc/mosaic
    environment:
      MOSAIC_STORAGE_PATH: /var/lib/mosaic/shards
      MOSAIC_AUTH_ENABLED: "false"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4040/health"]
```

### 10.3 Install Script

```bash
curl -fsSL https://get.mosaicdb.io | bash
# → Detects OS, installs Docker or binary release
# → Starts mosaicdb on port 4040
# → Opens browser to local playground
```

**Effort:** 1 week

---

## Phase 11: Authentication & Multi-Tenancy

**Goal:** API keys, scoped permissions, tenant-isolated shards.

### 11.1 Authentication Layer

```
POST /api/auth/login    → JWT token
POST /api/auth/keys     → Create API key (scoped to tenant)
GET  /api/auth/me       → Current user/tenant

All subsequent requests: Authorization: Bearer <token>
                          or X-API-Key: mk_live_abc123
```

**Permissions model:**
```
Role: admin    → manage tenants, users, billing, full data access
Role: writer   → ingest, search, traverse (cannot delete shards)
Role: reader   → search, traverse (read-only)
Role: agent    → MCP access only (mosaic_* tools)
```

### 11.2 Multi-Tenancy

```
/shards/
├── tenant_abc123/          # Tenant A
│   ├── codebase_001.db
│   └── docs_2024.db
├── tenant_def456/          # Tenant B
│   └── knowledge_base.db
└── _system/                # Internal (users, billing, config)
    └── system.db
```

**ShardRouter with tenant isolation:**
```elixir
# Every query is scoped to the authenticated tenant
shards = Mosaic.ShardRouter.list_shards(tenant_id: current_tenant)
```

**Tenant management API:**
```
POST   /api/tenants              # Create tenant
GET    /api/tenants/:id           # Tenant details
GET    /api/tenants/:id/usage     # Query count, storage, active users
DELETE /api/tenants/:id           # Delete all tenant data
```

### 11.3 Billing Counters

Per-tenant counters persisted in `_system/system.db`:
```
tenant_usage:
  - queries_this_month: 142,301
  - storage_bytes: 2,147,483,648
  - active_users: 12
  - ingest_requests: 892
```

**Effort:** 3 weeks

---

## Phase 12: Helm Chart + Kubernetes

**Goal:** `helm install mosaicdb ./charts/mosaicdb` — HA deployment on any k8s.

### 12.1 Helm Chart Structure

```
charts/mosaicdb/
├── Chart.yaml
├── values.yaml
│   # replicaCount: 3
│   # storage: 100Gi (PVC)
│   # redis: enabled (for distributed cache)
│   # ingress: enabled (nginx/traefik)
│   # monitoring: enabled (prometheus + grafana)
│   # auth: enabled (JWT secret, API keys)
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── pvc.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── hpa.yaml              # Horizontal Pod Autoscaler
│   ├── servicemonitor.yaml   # Prometheus operator
│   └── networkpolicy.yaml
└── README.md
```

### 12.2 ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mosaicdb
spec:
  source:
    repoURL: https://github.com/allen-munsch/mosaic
    path: charts/mosaicdb
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: mosaicdb
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 12.3 Production Topology

```
                    ┌──────────────────┐
                    │   Load Balancer   │
                    │   (nginx/ALB)     │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │ Mosaic-0 │  │ Mosaic-1 │  │ Mosaic-2 │
        │  shards  │  │  shards  │  │  shards  │
        │  [0-99]  │  │[100-199] │  │[200-299] │
        └────┬─────┘  └────┬─────┘  └────┬─────┘
             │              │              │
             └──────────────┼──────────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
        ┌──────────┐               ┌──────────┐
        │  Redis   │               │  Object  │
        │  Cache   │               │  Store   │
        │ (shared) │               │  (S3)    │
        └──────────┘               └──────────┘
```

**Effort:** 2 weeks

---

## Phase 13: Enterprise Features

**Goal:** What companies with 100+ employees must have.

### 13.1 SSO / SAML / OIDC

```
Configured via:
  MOSAIC_OIDC_ISSUER=https://accounts.google.com
  MOSAIC_OIDC_CLIENT_ID=...
  MOSAIC_OIDC_CLIENT_SECRET=...

Supported:
  - Google Workspace
  - Okta
  - Azure AD / Entra ID
  - Auth0
  - Keycloak (self-hosted)
```

Implementation: [assent](https://github.com/pow-auth/assent) library (Elixir OAuth2/OIDC).

### 13.2 Audit Logging

Every mutation logged with timestamp, user, IP, action:
```
audit_logs:
  - ts: 2026-05-04T14:30:00Z
    user: alice@company.com
    action: query.search
    params: {query: "auth flow", limit: 10}
    ip: 10.0.1.42
    duration_ms: 23
  - ts: 2026-05-04T14:31:00Z
    user: bob@company.com
    action: admin.delete_tenant
    params: {tenant_id: "def456"}
    ip: 10.0.1.99
```

Stored in a dedicated SQLite audit shard, rotated monthly. Queryable via admin API.

### 13.3 SLA Support

```
Tier:       Free       Pro       Enterprise
────────────────────────────────────────────
Uptime:     best-effort 99.5%    99.9% (financially backed)
Support:    GitHub     Email     Slack + phone + dedicated TAM
Response:   best-effort 4 hours  15 minutes (P1)
Data residency: any    US/EU    custom region
```

### 13.4 Data Residency & Compliance

```
GDPR:
  - Data export: GET /api/admin/export/:tenant_id → all shards as .tar.gz
  - Data deletion: DELETE /api/admin/tenants/:id → cascading purge
  - Processing records: audit log covers all access

SOC2 (target):
  - Access controls: SSO + RBAC
  - Encryption: TLS in transit, optional at-rest (LUKS)
  - Monitoring: Prometheus + Grafana dashboards
  - Incident response: documented runbook
```

**Effort:** 3 weeks

---

## Phase 14: Benchmarks & Competitive Analysis

**Goal:** Published, reproducible benchmarks proving MosaicDB wins on hybrid queries and cost.

### 14.1 Benchmark Suite

```
benches/
├── hybrid_search.exs        # Vector + SQL filter latency vs Pinecone/pgvector
├── federated_analytics.exs  # DuckDB aggregation vs separate analytics DB
├── ingest_throughput.exs    # Docs/sec vs Qdrant/Weaviate
├── recall_at_k.exs         # ANN benchmark recall-10, recall-100
├── storage_efficiency.exs  # GB per 1M docs vs competitors
├── concurrent_load.exs     # 1000 concurrent queries
└── results/                # JSON + Grafana dashboards
```

### 14.2 Comparison Matrix (to publish)

```
                Pinecone  pgvector  Qdrant   MosaicDB
─────────────────────────────────────────────────────
Vector search     ✅        ✅        ✅        ✅
SQL filtering     ❌        ✅        ❌        ✅
Hybrid in 1 query ❌        partial   ❌        ✅  ← differentiator
Federated analytics❌       ❌        ❌        ✅  ← unique
Self-hosted       ❌        ✅        ✅        ✅
Shard as file     ❌        ❌        ❌        ✅  ← unique
MCP native        ❌        ❌        ❌        ✅  ← unique
Token compression ❌        ❌        ❌        ✅  ← unique
Edge deployable   ❌        ❌        ❌        ✅  ← unique
```

### 14.3 Published Benchmarks

```markdown
# Hybrid Vector + SQL: MosaicDB vs pgvector
100K documents, 384-dim embeddings
Query: semantic similarity + 3 SQL filters

MosaicDB: 12ms p50, 45ms p99
pgvector: 28ms p50, 120ms p99
→ 2.3x faster on hybrid queries

# Federated Analytics: MosaicDB vs pgvector + separate analytics
10M documents across 100 shards
Query: GROUP BY category, AVG(price)

MosaicDB (DuckDB): 340ms
pgvector + ClickHouse: 1,200ms (ETL + query)
→ 3.5x faster on cross-shard aggregations
```

**Effort:** 1 week

---

## Phase 15: Documentation & Developer Experience

**Goal:** A developer goes from zero to first query in under 5 minutes.

### 15.1 Documentation Site

```
docs.mosaicdb.io/
├── getting-started/
│   ├── quickstart.md         # curl | bash → first query in 60s
│   ├── docker.md
│   └── kubernetes.md
├── guides/
│   ├── hybrid-search.md      # Vector + SQL in one query
│   ├── code-graph.md         # Index a codebase, traverse call graph
│   ├── rag-pipeline.md       # RAG on documents
│   ├── mcp-agent.md          # Claude/Cursor integration
│   └── matryoshka.md         # RLM + MosaicDB together
├── api-reference/
│   ├── rest-api.md
│   ├── python-sdk.md
│   ├── js-sdk.md
│   └── mcp-tools.md
├── concepts/
│   ├── architecture.md
│   ├── sharding.md
│   ├── queries.md
│   └── ranking.md
├── deployment/
│   ├── docker.md
│   ├── kubernetes.md
│   ├── fly-io.md
│   └── bare-metal.md
└── comparisons/
    ├── vs-pinecone.md
    ├── vs-pgvector.md
    └── vs-qdrant.md
```

### 15.2 Interactive Playground

Single-page HTML app served by MosaicDB at `/playground`:
- Search bar → live results
- Graph visualization → D3.js force-directed
- SQL editor → DuckDB analytics
- "Try it" button → loads sample dataset (1,000 Wikipedia articles)

**Effort:** 2 weeks

---

## Phase 16: Connectors & Integrations

**Goal:** Ingest data from where it lives, not where MosaicDB is.

### 16.1 GitHub App

```
mosaicdb GitHub App → installed on org/repo
  → On push: re-index changed files
  → On PR: index diff, surface affected functions
  → PR comment: "This PR affects 3 functions called by 12 others"
```

### 16.2 Notion / Confluence / Google Drive

```
mosaic ingest notion://workspace/page-id    # via Notion API
mosaic ingest confluence://space/key         # via Confluence API
mosaic ingest gdrive://folder-id             # via Google Drive API
```

### 16.3 Slack Bot

```
/mosaic search "error handling"
  → Returns top 3 results inline
/mosaic ask "how does auth work?"
  → RAG retrieval + LLM-powered answer
```

### 16.4 Webhooks + CDC

```
POST /api/webhooks/ingest
  Body: { "url": "https://...", "type": "markdown" }
  → Downloads, chunks, indexes, returns handle

# Also: polling mode for S3/GCS buckets
mosaic ingest s3://my-bucket --watch   # polls every 60s
```

**Effort:** 3 weeks

---

## Implementation Order (Priority-Weighted)

| # | Phase | Weeks | Why First |
|---|-------|-------|-----------|
| 1 | **Python SDK** (Phase 9) | 2 | 90% of AI developers use Python |
| 2 | **Docker + Install** (Phase 10) | 1 | Frictionless eval → signups |
| 3 | **Benchmarks** (Phase 14) | 1 | Proof before anyone invests time |
| 4 | **Documentation** (Phase 15) | 2 | Tutorials convert visitors to users |
| 5 | **Auth + Multi-tenancy** (Phase 11) | 3 | Required for any paying customer |
| 6 | **JS SDK** (Phase 9) | 1 | Frontend + Node.js developers |
| 7 | **K8s + Helm** (Phase 12) | 2 | Enterprise self-hosted deals |
| 8 | **Enterprise** (Phase 13) | 3 | SSO, audit, SLA — closes enterprise |
| 9 | **Connectors** (Phase 16) | 3 | Expands TAM beyond code/doc files |

**Total: 18 weeks to full production readiness**

### MVP Launch (Week 6)

What ships at week 6:
- Python SDK on PyPI
- Docker image on Docker Hub
- Published benchmarks
- Documentation site with quickstart, API reference, comparisons
- Free tier: 10GB storage, 100K queries/month
- Launch on Hacker News, r/MachineLearning, r/elixir

### Enterprise Launch (Week 12)

What ships at week 12:
- Auth + multi-tenancy
- JS SDK
- Helm chart + ArgoCD
- SSO (Google/Okta)
- Pro tier: $99/mo, 100GB, 1M queries
- Enterprise: custom pricing, SLA, dedicated support

### Full Platform (Week 18)

What ships at week 18:
- Connectors (GitHub, Notion, Slack)
- Audit logging
- Managed cloud (mosaicdb.cloud)
- Admin dashboard
- Data residency options

# MosaicDB Helm Chart

Federated SQL Semantic Search & Analytics Engine with DuckDB, SQLite shards, Property Graph, and MCP server.

## Quick Start

```bash
helm repo add mosaicdb https://allen-munsch.github.io/mosaic
helm install mosaicdb mosaicdb/mosaicdb \
  --set persistence.enabled=true \
  --set persistence.size=50Gi
```

## Parameters

### Core

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `1` |
| `image.repository` | Container image | `mosaicdb` |
| `image.tag` | Image tag | `latest` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |

### Service & Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `service.type` | Service type | `ClusterIP` |
| `service.port` | HTTP port | `4040` |
| `ingress.enabled` | Enable ingress | `false` |
| `ingress.className` | Ingress class | `nginx` |
| `ingress.hosts` | Host rules | `[{host: mosaicdb.local}]` |
| `ingress.tls` | TLS config | `[]` |

### Persistence

| Parameter | Description | Default |
|-----------|-------------|---------|
| `persistence.enabled` | Enable PVC | `true` |
| `persistence.accessMode` | Access mode | `ReadWriteOnce` |
| `persistence.size` | Storage size | `50Gi` |
| `persistence.storageClass` | Storage class | `""` (default) |

### Resources & Scaling

| Parameter | Description | Default |
|-----------|-------------|---------|
| `resources.requests.memory` | Memory request | `2Gi` |
| `resources.requests.cpu` | CPU request | `1000m` |
| `resources.limits.memory` | Memory limit | `8Gi` |
| `resources.limits.cpu` | CPU limit | `4000m` |
| `autoscaling.enabled` | Enable HPA | `false` |
| `autoscaling.minReplicas` | Min replicas | `1` |
| `autoscaling.maxReplicas` | Max replicas | `10` |
| `autoscaling.targetCPUUtilizationPercentage` | CPU target | `70` |
| `autoscaling.targetMemoryUtilizationPercentage` | Memory target | `80` |
| `podDisruptionBudget.enabled` | Enable PDB | `false` |
| `podDisruptionBudget.minAvailable` | Min available pods | `1` |

### MosaicDB Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.storagePath` | Shard storage path | `/var/lib/mosaic/shards` |
| `config.routingDbPath` | Routing DB path | `/var/lib/mosaic/config/index.db` |
| `config.embeddingDim` | Embedding dimension | `384` |
| `config.embeddingProvider` | Provider (bumblebee/openai) | `bumblebee` |
| `config.indexStrategy` | Index strategy | `hnsw` |
| `config.cacheBackend` | Cache backend (ets/redis) | `ets` |
| `config.minSimilarity` | Min similarity threshold | `0.1` |
| `config.queryTimeout` | Query timeout (ms) | `10000` |
| `config.graphEnabled` | Enable graph DB | `true` |
| `config.handleRegistryEnabled` | Enable handle registry | `true` |

### Authentication

| Parameter | Description | Default |
|-----------|-------------|---------|
| `auth.enabled` | Enable auth (JWT + API key) | `false` |
| `auth.jwtSecret` | JWT signing secret | `""` (auto-generated in dev) |
| `auth.jwtIssuer` | JWT issuer | `mosaicdb` |
| `auth.jwtTTL` | JWT TTL in seconds | `86400` |

### Redis (Distributed Cache)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `redis.enabled` | Enable Redis | `false` |
| `redis.url` | Redis URL | `redis://redis:6379/1` |

### Cluster (Erlang Distribution)

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cluster.enabled` | Enable clustering | `false` |
| `cluster.secret` | Cluster secret | `mosaic-cluster-secret` |
| `cluster.gossipPort` | Gossip port | `45892` |

### Monitoring

| Parameter | Description | Default |
|-----------|-------------|---------|
| `monitoring.serviceMonitor.enabled` | Enable Prometheus ServiceMonitor | `false` |
| `monitoring.serviceMonitor.interval` | Scrape interval | `30s` |
| `monitoring.serviceMonitor.path` | Metrics path | `/metrics` |

### Security

| Parameter | Description | Default |
|-----------|-------------|---------|
| `networkPolicy.enabled` | Enable network policy | `false` |
| `serviceAccount.create` | Create service account | `true` |
| `serviceAccount.name` | Service account name | `""` (auto) |

## Production Deployment

```bash
helm install mosaicdb ./charts/mosaicdb \
  --namespace mosaicdb --create-namespace \
  --set replicaCount=3 \
  --set persistence.enabled=true \
  --set persistence.size=200Gi \
  --set ingress.enabled=true \
  --set ingress.hosts[0].host=mosaicdb.example.com \
  --set autoscaling.enabled=true \
  --set redis.enabled=true \
  --set auth.enabled=true \
  --set auth.jwtSecret="$(openssl rand -base64 32)" \
  --set monitoring.serviceMonitor.enabled=true \
  --set networkPolicy.enabled=true \
  --set podDisruptionBudget.enabled=true
```

## GitOps with ArgoCD

```bash
kubectl apply -f argocd/mosaicdb.yaml
# or multi-environment (dev/staging/prod):
kubectl apply -f argocd/appset.yaml
```

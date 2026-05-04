# MosaicDB Helm Chart

Federated SQL Semantic Search & Analytics Engine with DuckDB, SQLite shards, property graph, RAG pipeline, and MCP server.

## Quick Install

```bash
helm repo add mosaicdb https://allen-munsch.github.io/mosaic
helm install mosaicdb mosaicdb/mosaicdb \
  --set persistence.enabled=true \
  --set persistence.size=100Gi
```

## Parameters

### Core Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `1` |
| `image.repository` | Container image | `mosaicdb` |
| `image.tag` | Image tag | `latest` |
| `image.pullPolicy` | Pull policy | `IfNotPresent` |

### Service & Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `service.type` | Service type | `ClusterIP` |
| `service.port` | HTTP port | `4040` |
| `ingress.enabled` | Enable ingress | `false` |
| `ingress.className` | Ingress class | `nginx` |
| `ingress.hosts` | Host rules | `mosaicdb.local` |

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

### Authentication

| Parameter | Description | Default |
|-----------|-------------|---------|
| `auth.enabled` | Enable auth (JWT + API keys) | `false` |
| `auth.jwtSecret` | JWT signing secret | auto-generated |
| `auth.apiKeyEncryptionKey` | API key encryption key | auto-generated |

### MosaicDB Config

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.storagePath` | Shard storage path | `/var/lib/mosaic/shards` |
| `config.routingDbPath` | Routing DB path | `/var/lib/mosaic/config/index.db` |
| `config.embeddingModel` | Embedding model | `local` |
| `config.embeddingDim` | Embedding dimensions | `384` |
| `config.embeddingProvider` | Provider | `bumblebee` |
| `config.indexStrategy` | Index strategy | `hnsw` |
| `config.cacheBackend` | Cache backend | `ets` |
| `config.minSimilarity` | Min cosine similarity | `0.1` |
| `config.queryTimeout` | Query timeout (ms) | `10000` |
| `config.graphEnabled` | Enable graph DB | `true` |
| `config.handleRegistryEnabled` | Enable handle registry | `true` |

### Features

| Parameter | Description | Default |
|-----------|-------------|---------|
| `mcp.enabled` | Enable MCP server | `false` |
| `redis.enabled` | Enable Redis cache | `false` |
| `redis.url` | Redis URL | `redis://redis:6379/1` |
| `cluster.enabled` | Enable Erlang clustering | `false` |
| `cluster.gossipPort` | Gossip protocol port | `45892` |

### Security & Monitoring

| Parameter | Description | Default |
|-----------|-------------|---------|
| `networkPolicy.enabled` | Enable NetworkPolicy | `false` |
| `podDisruptionBudget.enabled` | Enable PDB | `false` |
| `podDisruptionBudget.minAvailable` | Min available pods | `1` |
| `monitoring.serviceMonitor.enabled` | Enable ServiceMonitor | `false` |
| `monitoring.serviceMonitor.interval` | Scrape interval | `30s` |

## Production Example

```bash
helm install mosaicdb ./charts/mosaicdb \
  --set replicaCount=3 \
  --set persistence.enabled=true \
  --set persistence.size=200Gi \
  --set ingress.enabled=true \
  --set 'ingress.hosts[0].host=mosaicdb.example.com' \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=3 \
  --set autoscaling.maxReplicas=10 \
  --set auth.enabled=true \
  --set mcp.enabled=true \
  --set redis.enabled=true \
  --set monitoring.serviceMonitor.enabled=true \
  --set networkPolicy.enabled=true \
  --set podDisruptionBudget.enabled=true
```

## GitOps

### ArgoCD

```bash
kubectl apply -f argocd/mosaicdb.yaml
# Multi-environment: kubectl apply -f argocd/appset.yaml
```

### Flux

```bash
flux create source git mosaicdb --url=https://github.com/allen-munsch/mosaic --branch=main
flux create helmrelease mosaicdb --source=GitRepository/mosaicdb \
  --chart=./charts/mosaicdb --target-namespace=mosaicdb
```
